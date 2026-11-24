/*
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <AK/JsonValue.h>
#include <AK/LexicalPath.h>
#include <AK/QuickSort.h>
#include <AK/StringBuilder.h>
#include <LibCore/DirIterator.h>
#include <LibCore/Directory.h>
#include <LibCore/File.h>
#include <LibCore/Process.h>
#include <LibFileSystem/FileSystem.h>
#include <LibURL/URL.h>
#include <LibWebView/Application.h>
#include <LibWebView/UserScripts.h>

namespace WebView {

namespace {

struct UserScript {
    String name;
    String version;
    Vector<String> matches;
    Vector<String> includes;
    Vector<String> excludes;
    bool runs_at_document_start { false };
};

}

// Only "*" is special, and stands for any run of characters.
static bool glob_matches(StringView pattern, StringView text)
{
    size_t pattern_index = 0;
    size_t text_index = 0;
    Optional<size_t> star_index;
    size_t text_index_after_star = 0;

    while (text_index < text.length()) {
        if (pattern_index < pattern.length() && pattern[pattern_index] == '*') {
            star_index = pattern_index++;
            text_index_after_star = text_index;
        } else if (pattern_index < pattern.length() && pattern[pattern_index] == text[text_index]) {
            ++pattern_index;
            ++text_index;
        } else if (star_index.has_value()) {
            pattern_index = *star_index + 1;
            text_index = ++text_index_after_star;
        } else {
            return false;
        }
    }

    while (pattern_index < pattern.length() && pattern[pattern_index] == '*')
        ++pattern_index;
    return pattern_index == pattern.length();
}

// https://developer.chrome.com/docs/extensions/develop/concepts/match-patterns
static bool match_pattern_matches(StringView pattern, URL::URL const& url)
{
    if (pattern == "<all_urls>"sv)
        return true;

    auto scheme_end = pattern.find("://"sv);
    if (!scheme_end.has_value())
        return false;

    auto scheme = pattern.substring_view(0, *scheme_end);
    if (scheme != "*"sv && !scheme.equals_ignoring_ascii_case(url.scheme()))
        return false;

    auto host_and_path = pattern.substring_view(*scheme_end + 3);
    auto path_start = host_and_path.find('/');
    auto host = host_and_path.substring_view(0, path_start.value_or(host_and_path.length()));
    auto path = path_start.has_value() ? host_and_path.substring_view(*path_start) : "/*"sv;

    // A pattern without a port matches every port.
    if (auto port_start = host.find_last(':'); port_start.has_value() && !host.ends_with(']')) {
        auto port = host.substring_view(*port_start + 1);
        auto url_port = ByteString::number(url.port_or_default());
        if (port != "*"sv && port != url_port.view())
            return false;
        host = host.substring_view(0, *port_start);
    }

    auto url_host = url.serialized_host();
    if (host.starts_with("*."sv)) {
        auto domain = host.substring_view(2);
        auto is_domain = url_host.equals_ignoring_ascii_case(domain);
        auto is_subdomain = url_host.length() > domain.length()
            && url_host.ends_with(domain, CaseSensitivity::CaseInsensitive)
            && url_host[url_host.length() - domain.length() - 1] == '.';
        if (!is_domain && !is_subdomain)
            return false;
    } else if (host != "*"sv && !url_host.equals_ignoring_ascii_case(host)) {
        return false;
    }

    StringBuilder path_and_query;
    path_and_query.append(url.serialize_path());
    if (auto query = url.query(); query.has_value()) {
        path_and_query.append('?');
        path_and_query.append(*query);
    }
    return glob_matches(path, path_and_query.string_view());
}

static bool applies_to(UserScript const& script, URL::URL const& url, StringView url_without_fragment)
{
    for (auto const& exclude : script.excludes) {
        if (glob_matches(exclude.bytes_as_string_view(), url_without_fragment))
            return false;
    }

    if (script.matches.is_empty() && script.includes.is_empty())
        return true;

    for (auto const& match : script.matches) {
        if (match_pattern_matches(match.bytes_as_string_view(), url))
            return true;
    }
    for (auto const& include : script.includes) {
        if (glob_matches(include.bytes_as_string_view(), url_without_fragment))
            return true;
    }
    return false;
}

// Reads the ==UserScript== block. A source without a complete one is not a userscript.
static Optional<UserScript> parse_metadata(StringView source, StringView file_name)
{
    UserScript script;
    script.name = MUST(String::from_utf8(file_name));

    bool in_metadata_block = false;
    for (auto line : source.split_view('\n')) {
        line = line.trim_whitespace();
        if (!line.starts_with("//"sv))
            continue;
        line = line.substring_view(2).trim_whitespace();

        if (line == "==UserScript=="sv) {
            in_metadata_block = true;
            continue;
        }
        if (!in_metadata_block)
            continue;
        if (line == "==/UserScript=="sv)
            return script;
        if (!line.starts_with('@'))
            continue;

        auto key_end = line.find_any_of(" \t"sv);
        auto key = line.substring_view(1, key_end.value_or(line.length()) - 1);
        auto value = key_end.has_value() ? line.substring_view(*key_end).trim_whitespace() : StringView {};
        if (value.is_empty())
            continue;

        if (key == "name"sv)
            script.name = MUST(String::from_utf8(value));
        else if (key == "version"sv)
            script.version = MUST(String::from_utf8(value));
        else if (key == "match"sv)
            script.matches.append(MUST(String::from_utf8(value)));
        else if (key == "include"sv)
            script.includes.append(MUST(String::from_utf8(value)));
        else if (key == "exclude"sv)
            script.excludes.append(MUST(String::from_utf8(value)));
        else if (key == "run-at"sv)
            script.runs_at_document_start = value == "document-start"sv;
    }

    return {};
}

static String javascript_string_literal(StringView string)
{
    return JsonValue { MUST(String::from_utf8(string)) }.serialized();
}

// The script's source starts on the first line of the result, so the line numbers of its errors are its own.
static String wrap(UserScript const& script, StringView file_name, StringView source, StringView origin)
{
    auto name = javascript_string_literal(script.name.bytes_as_string_view());

    StringBuilder builder;
    builder.append("(function () { "sv);

    // The page that receives this may not be the one it was made for.
    builder.appendff("if (location.origin !== {}) return; ", javascript_string_literal(origin));

    // A document that is shown again, as one restored from history is, has run the script already.
    builder.appendff("const key = Symbol.for({}); ", javascript_string_literal(MUST(String::formatted("ladybird.userscript:{}", file_name))));
    builder.append("if (document[key]) return; "sv);
    builder.append("Object.defineProperty(document, key, { value: true }); "sv);

    builder.append("const run = function () { "sv);
    builder.append("const unsafeWindow = window; "sv);
    builder.appendff("const GM_info = {{ script: {{ name: {}, version: {} }}, scriptHandler: \"Ladybird\" }}; ", name, javascript_string_literal(script.version.bytes_as_string_view()));
    builder.append("const GM_addStyle = function (css) { const style = document.createElement(\"style\"); style.textContent = css; (document.head || document.documentElement).appendChild(style); return style; }; "sv);
    builder.append("try { (function () { "sv);
    builder.append(source);
    builder.append("\n}).call(window); } catch (error) { "sv);
    builder.appendff("console.error(\"Userscript \" + {} + \" failed:\", error); ", name);
    builder.append("} }; "sv);

    if (script.runs_at_document_start)
        builder.append("run(); "sv);
    else
        builder.append("if (document.readyState !== \"loading\") run(); else document.addEventListener(\"DOMContentLoaded\", run, { once: true }); "sv);

    builder.append("})();"sv);
    return builder.to_string_without_validation();
}

static ErrorOr<String> read_script(StringView path)
{
    auto file = TRY(Core::File::open(path, Core::File::OpenMode::Read));
    auto contents = TRY(file->read_until_eof());

    StringView source { contents.bytes() };
    if (source.starts_with("\xEF\xBB\xBF"sv))
        source = source.substring_view(3);
    return String::from_utf8(source);
}

ByteString user_scripts_directory()
{
    return LexicalPath::join(Application::profile().paths().config, "UserScripts"sv).string();
}

ErrorOr<void> show_user_scripts_directory()
{
#if defined(AK_OS_WINDOWS)
    return Error::from_string_literal("Opening the userscripts folder is not supported on this platform yet");
#else
    auto directory = user_scripts_directory();
    TRY(Core::Directory::create(directory, Core::Directory::CreateDirectories::Yes, 0700));

    // Like CrashReportStore, hand the folder to whatever the user's system opens folders with.
    Vector<ByteString> arguments { directory };
#    if defined(AK_OS_MACOS)
    TRY(Core::Process::spawn("/usr/bin/open"sv, arguments));
#    else
    TRY(Core::Process::spawn({
        .executable = "xdg-open"sv,
        .search_for_executable_in_path = true,
        .arguments = arguments,
    }));
#    endif
    return {};
#endif
}

Vector<String> user_script_sources_for(URL::URL const& url)
{
    Vector<String> sources;
    if (!url.scheme().is_one_of("http"sv, "https"sv))
        return sources;

    auto directory = user_scripts_directory();
    if (!FileSystem::is_directory(directory))
        return sources;

    Vector<ByteString> paths;
    Core::DirIterator iterator { directory, Core::DirIterator::SkipParentAndBaseDir };
    while (iterator.has_next()) {
        auto path = iterator.next_full_path();
        if (path.ends_with(".user.js"sv))
            paths.append(move(path));
    }
    quick_sort(paths);

    auto url_without_fragment = url.serialize(URL::ExcludeFragment::Yes);
    auto origin = url.origin().serialize();
    auto url_view = url_without_fragment.bytes_as_string_view();

    for (auto const& path : paths) {
        auto source = read_script(path);
        if (source.is_error()) {
            warnln("Unable to read userscript {}: {}", path, source.error());
            continue;
        }

        // File names need not be UTF-8, but the script's name and the key that marks it as run are strings.
        auto file_name_string = String::from_utf8_with_replacement_character(LexicalPath::basename(path));
        auto file_name = file_name_string.bytes_as_string_view();
        auto source_view = source.value().bytes_as_string_view();
        auto script = parse_metadata(source_view, file_name);
        if (!script.has_value()) {
            warnln("Skipping userscript {}: it has no ==UserScript== block", path);
            continue;
        }

        if (applies_to(*script, url, url_view))
            sources.append(wrap(*script, file_name, source_view, origin.bytes_as_string_view()));
    }

    return sources;
}

}
