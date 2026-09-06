// Prebuilt LiveView hooks for phoenix_kit_crm. Declared via `js_sources/0`;
// core's `:phoenix_kit_js_sources` compiler concatenates this (IIFE-wrapped)
// into the host's `phoenix_kit_modules.js` and folds `window.PhoenixKitCRMHooks`
// into `window.PhoenixKitHooks`.
window.PhoenixKitCRMHooks = window.PhoenixKitCRMHooks || {};

// CrmWhenWarnings — DISPLAY-ONLY helper for the interaction "When" field.
// Storage stays server-side (profile-tz -> UTC). This compares the field to the
// browser's live clock/timezone and writes advisory warnings into a sibling
// [data-when-warning] element:
//   • the time is in the past (the prefill went stale while the form sat open),
//   • the time is in the future,
//   • this device's timezone differs from the user's profile timezone.
// The field's value is a wall-clock time in the user's PROFILE timezone. The
// server passes that zone's offset RIGHT NOW in minutes (data-profile-offset-
// minutes), its label (data-profile-zone) for the message, and — when the
// profile is an IANA zone — its id (data-profile-zone-id), so the field's
// value can be read with the offset of ITS OWN date: a January time typed in
// July is an hour off under today's offset in any zone with daylight saving.
// A legacy fixed offset has no id and never moves, so the minutes are exact.
(function () {
  function fmtOffset(minutes) {
    var sign = minutes >= 0 ? "+" : "-";
    var abs = Math.abs(minutes);
    var h = Math.floor(abs / 60);
    var m = abs % 60;
    return "UTC" + sign + h + (m ? ":" + (m < 10 ? "0" : "") + m : "");
  }
  // Offset (minutes east of UTC) of an IANA zone at an instant, from the
  // browser's own tz database. null when the zone is unknown here.
  function zoneOffsetAt(zone, instantMs) {
    try {
      var parts = new Intl.DateTimeFormat("en-US", {
        timeZone: zone,
        hourCycle: "h23",
        year: "numeric",
        month: "2-digit",
        day: "2-digit",
        hour: "2-digit",
        minute: "2-digit",
        second: "2-digit",
      }).formatToParts(new Date(instantMs));
      var get = function (type) {
        return parseInt(parts.find(function (p) { return p.type === type; }).value, 10);
      };
      var wallAsUtc = Date.UTC(get("year"), get("month") - 1, get("day"), get("hour") % 24, get("minute"), get("second"));
      return Math.round((wallAsUtc - instantMs) / 60000);
    } catch (e) {
      return null;
    }
  }
  // A wall clock in the profile zone → its UTC instant, by the server's
  // rules: a wall clock that happens twice (fall-back) is its FIRST
  // occurrence, one that never happens (spring-forward gap) is the instant
  // the clocks jump to. Without an id the fixed offset applies.
  function wallToUtc(wall, zoneId, fixedOffsetMinutes) {
    // datetime-local is normally minute precision, but a browser (or a
    // non-zero step) can hand back seconds — the server's reader tolerates
    // both, so this one must too, or the warnings just vanish.
    var asUtc = Date.parse(wall + (/:\d\d:\d\d$/.test(wall) ? "" : ":00") + "Z");
    if (isNaN(asUtc)) return NaN;
    if (!zoneId) return asUtc - fixedOffsetMinutes * 60 * 1000;
    var day = 24 * 60 * 60 * 1000;
    var before = zoneOffsetAt(zoneId, asUtc - day);
    var after = zoneOffsetAt(zoneId, asUtc + day);
    if (before === null || after === null) return asUtc - fixedOffsetMinutes * 60 * 1000;
    // Candidates under each offset in force around that day; keep the ones
    // that read back as the same wall clock.
    var valid = [];
    [before, after].forEach(function (o) {
      var utc = asUtc - o * 60 * 1000;
      if (zoneOffsetAt(zoneId, utc) === o && valid.indexOf(utc) < 0) valid.push(utc);
    });
    if (valid.length) return Math.min.apply(null, valid);
    // A gap: bisect the switch between the two candidates for the instant
    // the new offset takes over.
    var lo = asUtc - before * 60 * 1000;
    var hi = asUtc - after * 60 * 1000;
    if (lo > hi) { var t = lo; lo = hi; hi = t; }
    var loOffset = zoneOffsetAt(zoneId, lo);
    for (var i = 0; i < 24 && hi - lo > 60 * 1000; i++) {
      var mid = lo + Math.floor((hi - lo) / 2);
      if (zoneOffsetAt(zoneId, mid) === loOffset) lo = mid; else hi = mid;
    }
    return hi;
  }
  function esc(s) {
    var d = document.createElement("div");
    d.textContent = s;
    return d.innerHTML;
  }

  window.PhoenixKitCRMHooks.CrmWhenWarnings = {
    mounted() {
      this.warnEl = document.getElementById(this.el.dataset.warningTarget || "");
      this.setNowEl = document.getElementById(this.el.dataset.setnowTarget || "");
      this._h = () => this.refresh();
      this.el.addEventListener("input", this._h);
      this.timer = setInterval(this._h, 20000); // catch drift while the form sits open
      this.refresh();
    },
    updated() {
      this.refresh();
    },
    destroyed() {
      this.el.removeEventListener("input", this._h);
      clearInterval(this.timer);
    },
    refresh() {
      var offset = parseInt(this.el.dataset.profileOffsetMinutes || "0", 10);
      var zone = this.el.dataset.profileZone || fmtOffset(offset);
      var zoneId = this.el.dataset.profileZoneId || "";
      var warns = [];

      // getTimezoneOffset() is minutes WEST of UTC, hence the sign flip.
      var browserOffset = -new Date().getTimezoneOffset();
      if (browserOffset !== offset) {
        warns.push(
          "Your timezone is set to " +
            zone +
            ", but this device is " +
            fmtOffset(browserOffset) +
            ". Times are saved using your profile timezone."
        );
      }

      var val = this.el.value;
      var isNow = false;
      if (val) {
        // Field is profile-local wall-clock → its true UTC instant, with the
        // offset that applies on the field's own date.
        var fieldUtc = wallToUtc(val, zoneId, offset);
        if (!isNaN(fieldUtc)) {
          // Round DOWN to whole minutes (the field has minute precision, so this
          // is the wall-clock minute difference — "4 min ago" until the 5th ticks).
          var diffMin = Math.floor((Date.now() - fieldUtc) / 60000);
          if (diffMin >= 1) {
            warns.push(
              "This is " +
                diffMin +
                " minute" +
                (diffMin === 1 ? "" : "s") +
                " in the past."
            );
          } else if (diffMin < 0) {
            warns.push("This time is in the future.");
          } else {
            isNow = true; // same minute as the current time
          }
        }
      }

      if (this.warnEl) {
        this.warnEl.innerHTML = warns
          .map(function (w) {
            return "<div>⚠ " + esc(w) + "</div>";
          })
          .join("");
      }

      // "Set to now" is only useful when the field isn't already "now".
      if (this.setNowEl) this.setNowEl.classList.toggle("hidden", isNow);
    },
  };
})();

