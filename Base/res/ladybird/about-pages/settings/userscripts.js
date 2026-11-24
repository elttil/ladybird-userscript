// Out-of-tree patch: see Libraries/LibWebView/UserScripts.h.
const userScriptsDirectory = document.querySelector("#userscripts-directory");
const userScriptsStatus = document.querySelector("#userscripts-status");

document.querySelector("#open-userscripts-directory").addEventListener("click", () => {
    userScriptsStatus.hidden = true;
    ladybird.sendMessage("showUserScriptsDirectory");
});

document.addEventListener("WebUILoaded", () => {
    ladybird.sendMessage("loadUserScriptsDirectory");
});

document.addEventListener("WebUIMessage", event => {
    const { name, data } = event.detail;
    if (name === "userScriptsDirectory") {
        userScriptsDirectory.textContent = data;
    } else if (name === "userScriptsStatus") {
        userScriptsStatus.textContent = data;
        userScriptsStatus.hidden = !data;
    }
});
