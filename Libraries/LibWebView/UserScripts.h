/*
 * SPDX-License-Identifier: BSD-2-Clause
 */

#pragma once

#include <AK/String.h>
#include <AK/Vector.h>
#include <LibURL/Forward.h>
#include <LibWebView/Export.h>

namespace WebView {

// Out-of-tree patch: minimal userscript support, until Ladybird has its own.
//
// Every *.user.js file in the "UserScripts" folder of the profile's config directory (next to Settings.json) is read
// again for each new top-level document, so adding, editing or deleting a file takes effect on the next page load.
//
// From the ==UserScript== block these keys are honored: @name, @version, @match, @include (globs only), @exclude
// (globs only) and @run-at. A script that names neither @match nor @include runs on every page. A file without a
// ==UserScript== block is skipped.
//
// Limits, by design:
//   - Scripts run in the page's own JavaScript world, as "@grant none" scripts do. unsafeWindow, GM_info and
//     GM_addStyle exist; no other GM_* function does.
//   - Scripts are sent to the page once the browser learns of its new document, so "@run-at document-start" means
//     as early as possible, not before the page's own scripts.
//   - Only http: and https: top-level documents get scripts; frames do not.
//
// Returns the JavaScript to run in the document at the given URL, one string for each script that applies.
WEBVIEW_API Vector<String> user_script_sources_for(URL::URL const&);

}
