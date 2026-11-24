// What register.js tells the page about where it runs, as pure functions
// (test/js/pwa_platform.test.js).

// iPadOS reports itself as a Mac: a Mac with a touch screen is an iPad.
export function platform(userAgent, maxTouchPoints) {
  if (/iPad|iPhone|iPod/.test(userAgent) || (/Macintosh/.test(userAgent) && maxTouchPoints > 1)) return "ios";
  if (/Android/.test(userAgent)) return "android";
  return "other";
}

// A chat or social app's built-in browser, guessed from its user agent:
// it can't install the app. WhatsApp's, on iOS, can't be told from Safari.
const IN_APP = /Instagram|FBAN|FBAV|FB_IAB|LinkedInApp|\bLine\/|TikTok|musical_ly|BytedanceWebview|Telegram/;

export const inApp = (userAgent) => IN_APP.test(userAgent);

// The install banner: on iOS, where Add to Home Screen is the way (the
// sheet says how), or on Android once Chrome offered its own prompt; never
// in the installed app itself, nor on a desktop.
export const showInstall = ({ platform, standalone, installable }) =>
  !standalone && (platform === "ios" || (platform === "android" && installable));
