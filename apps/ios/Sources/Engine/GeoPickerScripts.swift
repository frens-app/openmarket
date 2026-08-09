import Foundation

/// The scripts that drive Facebook's own location picker.
///
/// Facebook will not take a coordinate as a URL parameter — measured, and it
/// silently serves the IP city instead (`docs/location-targeting.md` §4). But
/// the "Change location" dialog has a centring arrow that asks the *browser*
/// where it is, and it accepts whatever answer it gets: fed London from a
/// Toronto session behind a San Francisco IP, it resolved to London (§5a, and
/// §5b for the same result inside `WKWebView`).
///
/// So Facebook does the place resolution, and the app never guesses a slug.
enum GeoPickerScripts {
    /// Replaces `navigator.geolocation` with one that answers from
    /// `window.__geoFeed`, injected at document start.
    ///
    /// Two things make this the right shape rather than granting the web view
    /// real location access:
    ///
    /// * WKWebView's own Geolocation support has never been dependable, so
    ///   relying on it would make this work by luck.
    /// * `__geoFeed` starts **null**, and every call errors until the app sets
    ///   it. Facebook cannot obtain a position at a moment of its choosing —
    ///   only the one the app hands over, at the moment it hands it over. The
    ///   web view has no location permission of its own to leak.
    static let feeder = """
    (function(){
      if (window.__geoFedHooked) return;
      window.__geoFedHooked = true;
      window.__geoFeed = null;
      window.__geoFedCalls = 0;
      function position() {
        return {
          coords: {
            latitude: window.__geoFeed.lat, longitude: window.__geoFeed.lon,
            accuracy: 20, altitude: null, altitudeAccuracy: null,
            heading: null, speed: null
          },
          timestamp: Date.now()
        };
      }
      function getCurrentPosition(ok, err) {
        window.__geoFedCalls++;
        if (!window.__geoFeed) {
          // PERMISSION_DENIED — the honest answer when the app hasn't offered
          // a coordinate, and the one a page handles gracefully.
          if (err) err({ code: 1, message: 'denied' });
          return;
        }
        setTimeout(function(){ ok(position()); }, 0);
      }
      function watchPosition(ok, err) { getCurrentPosition(ok, err); return 1; }
      var impl = { getCurrentPosition: getCurrentPosition,
                   watchPosition: watchPosition,
                   clearWatch: function(){} };
      var g = navigator.geolocation;
      if (!g) {
        Object.defineProperty(navigator, 'geolocation', { value: impl, configurable: true });
      } else {
        Object.defineProperty(g, 'getCurrentPosition', { value: getCurrentPosition, writable: true, configurable: true });
        Object.defineProperty(g, 'watchPosition', { value: watchPosition, writable: true, configurable: true });
      }
    })();
    """

    /// Arms the feed with a coordinate. Nothing reads it until the arrow is
    /// clicked, so this is safe to call before the dialog exists.
    static func arm(latitude: Double, longitude: Double) -> String {
        """
        (function(){
          window.__geoFeed = { lat: \(latitude), lon: \(longitude) };
          return JSON.stringify({ armed: !!window.__geoFedHooked });
        })()
        """
    }

    /// Finding the header pill, by what it *is* rather than what it says.
    ///
    /// **The aria-label is the target; the text is the fallback.** This used to
    /// be a text match alone — the first `div[role="button"]` whose text looked
    /// like "San Francisco · 40 mi" — and that is a description of the pill's
    /// current typography, not of the pill. Logged out it matched exactly one
    /// element and worked for months. Signed in, the logged-in chrome puts more
    /// buttons on the page, the first match was **the notifications button**,
    /// and clicking it opened the notifications flyout: the dialog we then
    /// searched for a centring arrow contained "Notification Actions |
    /// Notifications filters | 3 days ago".
    ///
    /// The label is written for a screen reader, so it spells the place out in
    /// full — "Location: San Francisco, California" — no matter how the visible
    /// chip is abbreviated, it carries no distance formatting to disagree about,
    /// and nothing else on the page claims to be a Location button.
    /// `DesktopScripts.extractLocationPill` reached the same conclusion for the
    /// same reason; this file just never got the benefit of it.
    ///
    /// A click React will actually believe.
    ///
    /// `element.click()` dispatches a lone `click` event. That is enough for a
    /// handler bound to `onClick`, and **not** enough for Facebook's location
    /// pill, which opens on the pointer sequence: measured signed in, clicking
    /// the correct pill left `aria-expanded` null, no dialog mounted, and no
    /// `Apply` or geolocation control anywhere in the document. Same family as
    /// the WebLite tap problem in `docs/feasibility-2026-07-31.md` — a
    /// synthesized event that satisfies the DOM and not the framework.
    ///
    /// So this plays the whole sequence, at the element's own centre, with
    /// `composed: true` so it crosses shadow boundaries. `PointerEvent` is
    /// constructed where available and falls back to `MouseEvent`, because a
    /// throw here would abort the rest of the sequence and look exactly like
    /// the bug it fixes.
    private static let realClick = """
      function realClick(el){
        var r = el.getBoundingClientRect();
        var x = r.left + r.width / 2, y = r.top + r.height / 2;
        // Aim at whatever is actually on top at that point, then walk back up to
        // the element we meant if the hit lands outside it. Facebook nests the
        // handler below the labelled `role="button"` often enough that
        // dispatching on the labelled ancestor alone reaches nothing — events
        // bubble up, they do not travel down to a particular child.
        // Only hit-test a laid-out element. A zero box means `elementFromPoint`
        // is asked about 0,0 and returns whatever is in the top-left corner —
        // which is how aiming at the location pill became a click on the page
        // header.
        if (r.width > 0 && r.height > 0) {
          var hit = document.elementFromPoint(x, y);
          if (hit && (el.contains(hit) || hit.contains(el))) el = hit;
        }
        var base = { bubbles: true, cancelable: true, composed: true,
                     clientX: x, clientY: y, view: window, button: 0 };
        var order = ['pointerover','pointerenter','pointermove','pointerdown',
                     'mousedown','pointerup','mouseup','click'];
        for (var i = 0; i < order.length; i++) {
          var type = order[i], ev = null;
          var isPointer = type.indexOf('pointer') === 0;
          try {
            if (isPointer && window.PointerEvent) {
              var opts = {}; for (var k in base) opts[k] = base[k];
              opts.pointerId = 1; opts.isPrimary = true; opts.pointerType = 'mouse';
              ev = new PointerEvent(type, opts);
            } else if (!isPointer) {
              ev = new MouseEvent(type, base);
            }
          } catch (e) { ev = null; }
          if (ev) el.dispatchEvent(ev);
        }
      }
    """

    /// `role="button"` is load-bearing: the dialog's own search field is an
    /// `input[role="combobox"]` whose label is also `Location`.
    private static let locatePill = """
      function locationPill(){
        var labelled = document.querySelector('div[role="button"][aria-label^="Location"]');
        if (labelled) return labelled;
        return Array.prototype.slice.call(document.querySelectorAll('div[role="button"]'))
          .filter(function(e){ var t = (e.textContent||'').trim();
                               return /·\\s*\\d+\\s*(mi|km)/i.test(t) && t.length < 80; })[0] || null;
      }
    """

    /// Is the header pill there yet?
    ///
    /// Split out from `openDialog` so the caller can *wait* for it. A fixed
    /// sleep was both too long and too short: on a run where the page took
    /// 4.2 s to load, the pill still wasn't drawn 4 s later and the whole
    /// resolution failed.
    /// Ready means **laid out**, not merely in the DOM.
    ///
    /// Existence is the wrong bar. The pill is inserted before it has a box,
    /// and clicking it in that state does nothing: measured across runs, the
    /// same element reported `344x27 @8,569` on one attempt and `0x0 @0,0` on
    /// the next, which is the whole of why this failed intermittently rather
    /// than always. Waiting for a real rectangle costs one more poll and
    /// removes the race.
    static let pillPresent = """
    (function(){
    \(locatePill)
      var pill = locationPill();
      if (!pill) return JSON.stringify({ ready: false });
      var r = pill.getBoundingClientRect();
      return JSON.stringify({ ready: r.width > 0 && r.height > 0 });
    })()
    """

    /// Is the centring arrow there yet? The dialog animates in.
    static let arrowPresent = """
    (function(){
      return JSON.stringify({
        ready: !!document.querySelector('[aria-label="Marketplace geolocation picker"]')
      });
    })()
    """

    /// Has the picker finished reverse-geocoding?
    ///
    /// Applying before it lands commits the *old* place, so this has to be
    /// waited for. The tempting signal — "the dialog's text changed" — is a
    /// trap: re-resolving the city you are already in produces the same text,
    /// and the wait then burns its whole timeout on a request that finished
    /// immediately. Measured: 12.3 s of a 20 s resolution, spent waiting for
    /// San Francisco to stop being San Francisco.
    ///
    /// The arrow itself is the place-independent signal. Clicking it replaces
    /// it with a spinner, and it returns when the answer arrives — so "gone,
    /// then back" means done regardless of what the answer was.
    static let armArrowLatch = """
    (function(){ window.__arrowWentBusy = false; return JSON.stringify({ ready: true }); })()
    """

    static let arrowSettled = """
    (function(){
      var present = !!document.querySelector('[aria-label="Marketplace geolocation picker"]');
      if (!present) window.__arrowWentBusy = true;
      return JSON.stringify({ ready: !!window.__arrowWentBusy && present });
    })()
    """

    /// Remembers the URL, so the navigation Apply triggers can be waited for
    /// instead of slept through.
    static let snapshotURL = """
    (function(){ window.__urlSnapshot = location.href;
                 return JSON.stringify({ ready: true }); })()
    """

    static let urlChanged = """
    (function(){
      return JSON.stringify({ ready: location.href !== (window.__urlSnapshot || '') });
    })()
    """

    /// Opens the "Change location" dialog from the header pill.
    ///
    /// The pill's units follow the *place*, not the viewer — a Canadian
    /// location renders "Toronto · 8 km" — and matching only `mi` once made a
    /// perfectly good pill invisible.
    static let openDialog = """
    (function(){
    \(locatePill)
    \(realClick)
      var btn = locationPill();
      if (!btn) return JSON.stringify({ opened: false });
      realClick(btn);
      // What was clicked, always — the failure this replaced was silent
      // precisely because "a button was clicked" was the only thing reported,
      // and it was true of the wrong button.
      var r = btn.getBoundingClientRect();
      return JSON.stringify({
        opened: true,
        by: btn.getAttribute('aria-label') ? 'label' : 'text',
        was: (btn.getAttribute('aria-label') || btn.textContent || '').trim().slice(0, 60),
        // Is this document laid out at all? An unattached WKWebView can parse
        // and script a page while giving every element a zero box, and a
        // framework that hit-tests or measures on open then does nothing.
        rect: Math.round(r.width) + 'x' + Math.round(r.height) + ' @' + Math.round(r.left) + ',' + Math.round(r.top),
        viewport: window.innerWidth + 'x' + window.innerHeight,
        connected: btn.isConnected
      });
    })()
    """

    /// What the dialog actually contains, for when the arrow isn't in it.
    ///
    /// "The selector matched nothing" is not a diagnosis — it is the same
    /// result whether the dialog never opened, opened somewhere else, or opened
    /// with different markup. This reports all three so the log says which
    /// (`docs/probe-checklist.md` §2).
    static let describeDialog = """
    (function(){
    \(locatePill)
      function visible(el){
        var r = el.getBoundingClientRect();
        return r.width > 0 && r.height > 0 && el.closest('[aria-hidden="true"]') === null;
      }
      var dialogs = Array.prototype.slice.call(document.querySelectorAll('[role="dialog"]'));
      var described = dialogs.slice(0, 6).map(function(d){
        return {
          visible: visible(d),
          label: d.getAttribute('aria-label'),
          text: (d.innerText || '').replace(/\\s+/g, ' ').slice(0, 70)
        };
      });
      var pill = locationPill();
      return JSON.stringify({
        dialogs: dialogs.length,
        described: described,
        // Anywhere on the page, not just inside a dialog — the picker may not
        // be wrapped in one at all.
        geoPickerAnywhere: !!document.querySelector('[aria-label="Marketplace geolocation picker"]'),
        geoish: Array.prototype.slice.call(document.querySelectorAll('[aria-label]'))
          .map(function(e){ return e.getAttribute('aria-label') || ''; })
          .filter(function(l){ return /geolocation|current location|locate|Apply|radius/i.test(l); })
          .slice(0, 8).join(' | '),
        pillStillThere: !!pill,
        pillExpanded: pill ? pill.getAttribute('aria-expanded') : null,
        url: location.href.slice(0, 120)
      });
    })()
    """

    /// Clicks the centring arrow, which calls the shim and waits on it.
    static let clickArrow = """
    (function(){
    \(realClick)
      var arrow = document.querySelector('[aria-label="Marketplace geolocation picker"]');
      if (!arrow) return JSON.stringify({ clicked: false });
      var before = window.__geoFedCalls;
      realClick(arrow);
      return JSON.stringify({ clicked: true, called: window.__geoFedCalls > before });
    })()
    """

    /// Commits the resolved place.
    static let apply = """
    (function(){
    \(realClick)
      var apply = document.querySelector('[aria-label="Apply"]');
      if (!apply) return JSON.stringify({ applied: false });
      realClick(apply);
      return JSON.stringify({ applied: true });
    })()
    """

    /// The pill's place name and the URL, after everything has settled. These
    /// are the two things worth keeping: the name to show the user, the URL
    /// segment to search with.
    static let readResult = """
    (function(){
      var pill = Array.prototype.slice.call(document.querySelectorAll('div[role="button"],span'))
        .map(function(e){ return (e.textContent||'').trim(); })
        .filter(function(t){ return /·\\s*\\d+\\s*(mi|km)/i.test(t) && t.length < 60; })[0] || null;
      var name = pill ? pill.split('·')[0].trim() : null;
      // The raw pill goes back untouched as well as parsed — `DesktopLocationPill`
      // reads the radius out of it, and an unexpected format is only
      // debuggable if the original text survives (probe checklist §2).
      return JSON.stringify({ name: name, pill: pill, url: location.href });
    })()
    """
}
