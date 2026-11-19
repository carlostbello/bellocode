import Foundation

/// The session instruction entry `bellocode.chrome` (docs/features/shared-browser.md "Agent guidance"), rendered by
/// opencode as `<context key="bellocode.chrome">`. No secrets, URLs of pages or titles: only the rules and names.
public enum BrowserGuidance {
    public static func text(projectLabel: String, group: String, mainTab: String) -> String {
        """
        BelloCode gives you two browsers. Pick deliberately.
        - Built-in preview (`browser.*`, WebKit in BelloCode's window): for quick looks at this project's dev server and \
        UI checks. It is WebKit, not Chromium.
        - Shared Chrome (`chrome_*` tools, browse in a real Chromium in BelloCode's container): when you need a real \
        Chrome-family browser: sites the person is signed in to (intranet, GitLab, SSO), extensions, Chrome-only behaviour, \
        downloads, or a person to take over (handoff).
        Sign-ins in the shared Chrome are the person's and are shared by every thread allowed to use it. Act only as the \
        task needs; never change account settings, sign out, or submit anything irreversible without asking.
        Your tabs: group \(group); calls without `tab` go to your default tab \(mainTab). `tabs` action `new` opens more \
        tabs in your group; `tabs` action `list` shows yours and any the person shared with you. Do not use other threads' \
        tabs. A "Busy" result means another thread drives that tab or the person took over: wait or use your own tab, \
        never retry in a loop. Close tabs you no longer need.
        Project URLs: open this project's dev server as https://\(projectLabel).bc:<port>/ and its services as \
        https://<service>.\(projectLabel).bc/ (not localhost: localhost inside the shared Chrome is the container itself). \
        The dev server must listen on that port inside the workspace and accept the host \(projectLabel).bc (for Vite: \
        server.allowedHosts). The same URLs work in the built-in preview.
        When only a person can continue (sign-in, 2FA, captcha, payment), call `handoff` and wait.
        """
    }
}
