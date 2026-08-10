import Foundation

/// JavaScript injected into the results and detail pages.
///
/// Facebook's mobile surface is WebLite — a server-driven UI where cards are
/// `data-mcomponent` containers keyed by an opaque `data-action-id`. There are
/// no listing anchors and no ids anywhere in the DOM, so:
///   • cards are found structurally (a container holding an fbcdn image and an h3),
///   • the scripts return *raw* text runs and let Swift classify them (§6 keeps
///     interpretation testable outside a webview),
///   • the canonical item URL is resolved by clicking a card and catching the
///     navigation, which the feed cancels (see FeedEngine).
enum WebLiteScripts {

    /// Shared card-finding logic. Innermost container that holds both an image
    /// and a text block is the card; anything that contains another such
    /// container is a grid, not a card.
    /// Card markup differs between surfaces — search results wrap text in `h3`,
    /// category pages don't — so the only reliable signal is structural: an
    /// actionable container holding a listing photo, innermost first.
    /// A TreeWalker over SHOW_TEXT visits the contents of <script> and <style>
    /// too, which is how a page's JavaScript ended up rendered as a listing
    /// description. Everything that reads text nodes must go through this.
    private static let textGuard = """
    function __mpTextOf(node) {
      var parent = node.parentElement;
      if (!parent) return null;
      var tag = parent.tagName;
      if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT' || tag === 'TEMPLATE') return null;
      var t = (node.textContent || '').trim();
      return t || null;
    }
    """

    private static let cardFinder = """
    \(textGuard)
    // Listing photos are served from scontent-*.xx.fbcdn.net. Facebook's own
    // chrome (the wordmark, icons) is on static.xx.fbcdn.net/rsrc.php, so
    // matching "fbcdn" alone picks up the header logo and lets a card grow
    // outward until it swallows its neighbour.
    function __mpIsListingPhoto(img) {
      var src = img.getAttribute('src') || '';
      return src.indexOf('scontent') !== -1 && src.indexOf('rsrc.php') === -1;
    }
    function __mpListingImages(el) {
      var imgs = el.querySelectorAll('img'), n = 0;
      for (var i = 0; i < imgs.length; i++) {
        if (__mpIsListingPhoto(imgs[i])) n++;
      }
      return n;
    }
    // Containment is the wrong model for this markup: a listing's photo and its
    // text can live in sibling subtrees, so no single ancestor holds one whole
    // card without also holding the next. Document order is reliable instead —
    // every text node between one listing photo and the next belongs to that
    // listing. This walks the page once and buckets accordingly.
    // Every search card labels itself with far more than it renders:
    //   "Desk for sale - Used - Good - $75 in Oakland, CA"
    //   "Free Computer desk for sale - Used - Like New in El Sobrante, CA"
    // The label carries the *untruncated* title, the condition and the city,
    // none of which reach the rendered text on every layout. Read it off the
    // listing's own image rather than searching the container: a
    // `querySelector('[aria-label]')` can cross into a neighbouring card, and
    // the photo is unambiguously this listing's.
    function __mpCardLabel(img, action) {
      var alt = img.getAttribute('alt');
      if (alt && alt.length > 12) return alt;
      if (action) {
        var own = action.getAttribute('aria-label');
        if (own && own.length > 12) return own;
      }
      return null;
    }
    function __mpCards() {
      var walker = document.createTreeWalker(
        document.body,
        NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT,
        null
      );
      var cards = [], current = null, node;
      while ((node = walker.nextNode())) {
        if (node.nodeType === 1 && node.tagName === 'IMG' && __mpIsListingPhoto(node)) {
          var action = node.closest ? node.closest('[data-action-id]') : null;
          current = {
            element: action || node.parentElement,
            imageURL: node.getAttribute('src'),
            actionId: action ? action.getAttribute('data-action-id') : null,
            label: __mpCardLabel(node, action),
            texts: []
          };
          cards.push(current);
        } else if (node.nodeType === 3 && current) {
          var t = __mpTextOf(node);
          // Guard against the page furniture that trails the final card.
          if (t && t.length < 120) current.texts.push(t);
        }
      }
      return cards;
    }
    """

    /// Returns every card on the page as raw fields. Classification happens in Swift.
    static var extract: String {
        """
        (function(){
          \(cardFinder)
          var cards = __mpCards();
          var out = [];
          for (var i = 0; i < cards.length; i++) {
            var card = cards[i];
            out.push({
              index: i,
              actionId: card.actionId,
              imageURL: card.imageURL,
              label: card.label,
              texts: card.texts,
              fullText: card.texts.join(' | ').slice(0, 300)
            });
          }
          return JSON.stringify({
            cards: out,
            docHeight: document.body.scrollHeight,
            loginWall: /you must log in|log into facebook to continue/i.test(document.body.innerText || ''),
            url: window.location.href
          });
        })()
        """
    }

    /// Taps the card at `index`. The resulting navigation carries the item id;
    /// the feed's navigation delegate captures and cancels it.
    ///
    /// WebLite binds its handlers differently across surfaces — a synthetic
    /// mouse sequence navigates on search results but does nothing on category
    /// pages — and the binding is server-driven, so it can change without
    /// notice. Rather than depend on one gesture, send touch, mouse, and a
    /// native `click()`: the first one the page listens for wins, and the
    /// others are inert. Callers must still tolerate no navigation at all.
    static func click(index: Int) -> String {
        """
        (function(){
          \(cardFinder)
          var cards = __mpCards();
          var el = cards[\(index)] ? cards[\(index)].element : null;
          if (!el) return 'missing';
          var r = el.getBoundingClientRect();
          var cx = r.left + r.width / 2, cy = r.top + r.height / 2;

          function touch() {
            return new Touch({identifier: 1, target: el, clientX: cx, clientY: cy,
                              pageX: cx, pageY: cy, radiusX: 11, radiusY: 11, force: 1});
          }
          try {
            el.dispatchEvent(new TouchEvent('touchstart', {bubbles:true, cancelable:true, composed:true,
              touches:[touch()], targetTouches:[touch()], changedTouches:[touch()]}));
            el.dispatchEvent(new TouchEvent('touchend', {bubbles:true, cancelable:true, composed:true,
              touches:[], targetTouches:[], changedTouches:[touch()]}));
          } catch (e) {}

          var mouseOpts = {bubbles:true, cancelable:true, composed:true, clientX:cx, clientY:cy};
          ['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(t){
            try { el.dispatchEvent(new MouseEvent(t, mouseOpts)); } catch(e) {}
          });

          try { if (typeof el.click === 'function') el.click(); } catch (e) {}
          return 'tapped';
        })()
        """
    }

    static let pageMetrics = """
    (function(){
      return JSON.stringify({
        docHeight: document.body.scrollHeight,
        scrollY: Math.round(window.scrollY)
      });
    })()
    """

    /// Detail pages are ordinary documents and much richer than the cards — but
    /// they also carry "Related searches" and "Today's picks" modules holding
    /// *other people's* listings. Everything below is scoped to stop at the
    /// first of those markers, so neither the photo strip nor the description
    /// can pick up a neighbouring listing's content.
    static var extractDetail: String {
        """
    (function(){
      \(textGuard)
      var STOP = /^(Related searches|Today's picks|Similar listings|More like this|Suggested|You may also like|See all|Sponsored)/i;

      // Walk in document order, gathering this listing's own gallery, and stop
      // dead at the first related-content heading.
      // The seller's avatar is served from scontent like any listing photo, so
      // the gallery has to end where the seller section begins. Text keeps
      // accumulating past it — that is where the name and rating live.
      var SELLER_START = /^(Seller information|Seller details|About the seller)$/i;
      var inSellerSection = false;
      var photos = [], seenPhotoIDs = {};
      var walker = document.createTreeWalker(document.body,
        NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, null);
      var node, mainText = '';
      while ((node = walker.nextNode())) {
        if (node.nodeType === 3) {
          var t = __mpTextOf(node);
          if (!t) continue;
          if (STOP.test(t)) break;
          mainText += t + '\\n';
        } else if (node.tagName === 'IMG') {
          if (inSellerSection) continue;
          var src = node.getAttribute('src') || '';
          if (src.indexOf('scontent') === -1 || src.indexOf('rsrc.php') !== -1) continue;
          // Seller avatars are PNGs — including the shared grey placeholder,
          // byte-identical across sellers. Listing photos are always JPEG.
          if (src.split('?')[0].slice(-4).toLowerCase() === '.png') continue;
          // Same photo appears at several sizes; key on the fbcdn photo id.
          var parts = src.split('/').pop().split('_');
          var key = parts.length > 1 ? parts[1] : src;
          if (seenPhotoIDs[key]) continue;
          seenPhotoIDs[key] = 1;
          photos.push(src);
        }
      }

      // Descriptions run to several paragraphs. `after` captures one line of at
      // most 120 characters, so everything past the first line was silently
      // dropped. Collect every line until the next labelled section instead.
      // Paragraph breaks never reach mainText: the walk skips whitespace-only
      // nodes, so a blank line between paragraphs is gone before extraction and
      // the description renders as one collapsed wall of text. innerText keeps
      // them, and excludes script/style natively rather than by guard.
      var _bodyLines = (document.body.innerText || '').split(String.fromCharCode(10));
      var _BOUNDARY = /^(Details|Condition|Location|Seller information|Seller details|About the seller|Message|Save|Share|More|Send|Alert|Related searches|Today's picks)$/i;
      function textAfter(label) {
        var out = [], started = false;
        for (var _k = 0; _k < _bodyLines.length; _k++) {
          var _ln = _bodyLines[_k].trim();
          if (!started) {
            if (_ln.toLowerCase() === label.toLowerCase()) started = true;
            continue;
          }
          if (_ln.length > 0) {
            if (_BOUNDARY.test(_ln)) break;
            if (_ln.indexOf('Listed ') === 0) break;
          }
          out.push(_ln);
          if (out.length >= 60) break;
        }
        while (out.length > 0 && out[0] === '') out.shift();
        while (out.length > 0 && out[out.length - 1] === '') out.pop();
        // One blank line between paragraphs, never a run of them.
        var kept = [];
        for (var _m = 0; _m < out.length; _m++) {
          if (out[_m] === '' && kept.length > 0 && kept[kept.length - 1] === '') continue;
          kept.push(out[_m]);
        }
        return kept.length > 0 ? kept.join(String.fromCharCode(10)) : null;
      }

      function after(label) {
        var re = new RegExp(label + "\\\\s*\\\\n+([^\\\\n]{1,120})", 'i');
        var m = mainText.match(re);
        return m ? m[1].trim() : null;
      }

      var listed = (mainText.match(/Listed\\s+[^\\n]{1,40}/i) || [])[0] || null;
      if (listed) listed = listed.replace(/\\s+in\\s+[A-Z][A-Za-z .'-]*(,\\s*[A-Z]{2})?\\s*$/, '').trim();

      // Description. Some pages label it, most don't — the seller's text just
      // follows the condition — so fall back to picking the longest line that
      // isn't the title, the price, a date, a place, or a piece of chrome.
      // Login prompts are prose, not chrome words, so the exact-match CHROME
      // list below never caught them — and being long sentences they won the
      // "longest line" fallback outright. A QR sign-in modal once rendered as
      // a listing's description. Matched as substrings, not whole lines.
      var LOGIN_NOISE = /scan the qr code|codes match|log ?in to facebook|log into facebook|you must log ?in|create new account|forgot password|continue with (google|apple|facebook)|keep me signed in|buy and sell in your community|browse or sell items|marketplace is a convenient/i;

      var description = textAfter('Description');
      if (description && LOGIN_NOISE.test(description)) description = null;
      if (!description) {
        var CHROME = /^(Message|Save|Share|Details|Condition|Alert|More|See all|Log ?In|Sign ?Up|Marketplace|Home|Buying|Selling|Notifications|Inbox|Create new listing|Categories|Filters|Sort|Seller information|Send seller a message|Is this still available\\?)$/i;
        var pageTitle = document.title || '';
        var best = null;
        mainText.split('\\n').forEach(function(line){
          var t = line.trim();
          if (t.length < 15) return;
          if (CHROME.test(t)) return;
          if (LOGIN_NOISE.test(t)) return;                         // sign-in modal prose
          if (/^Listed\\b/i.test(t)) return;                       // "Listed 3 weeks ago…"
          if (/Location is approximate/i.test(t)) return;
          if (/^[A-Z][A-Za-z .'-]+,\\s*[A-Z]{2}$/.test(t)) return;  // a bare "Berkeley, CA"
          if (/^[$£€¥₹]/.test(t)) return;                          // price runs
          if (pageTitle.indexOf(t) !== -1) return;                 // the listing title
          if (!best || t.length > best.length) best = t;
        });
        description = best;
      }
      if (description) description = description.slice(0, 1500);

      // Seller identity renders only on the mobile item page. The name sits
      // directly above "Joined Facebook in YYYY"; a rating, when the seller has
      // one at all, looks like "4.8 (12)" on its own line.
      var _lines = mainText.split(String.fromCharCode(10))
                           .map(function(s){ return s.trim(); })
                           .filter(function(s){ return s.length > 0; });
      var _LABEL = /^(Seller information|Seller details|Details|Description|Condition|Location)$/i;
      // "Joined Facebook in YYYY" anchors the seller block, but the name is not
      // always the line directly above it — a rating and a count sit between
      // them. Walk back past anything made only of digits, dots and brackets.
      // WebLite renders its icons as private-use glyphs that arrive as text
      // nodes, so a candidate name has to contain real letters to be a name.
      function _hasLetters(s) {
        var n = 0;
        for (var k = 0; k < s.length; k++) {
          var c = s.charAt(k).toLowerCase();
          if (c >= 'a' && c <= 'z') { n++; if (n >= 2) return true; }
        }
        return false;
      }
      function _isScore(s) {
        for (var k = 0; k < s.length; k++) {
          if ('0123456789.() '.indexOf(s.charAt(k)) === -1) return false;
        }
        return true;
      }
      var sellerName = null, sellerJoined = null, sellerRating = null, sellerCount = null;
      for (var _i2 = 0; _i2 < _lines.length; _i2++) {
        var _ln = _lines[_i2];
        if (_ln.indexOf('Joined Facebook') !== 0) continue;
        sellerJoined = _ln;
        var _j = _i2 - 1;
        while (_j >= 0 && (_isScore(_lines[_j]) || !_hasLetters(_lines[_j]))) {
          var _s = _lines[_j];
          if (_s.charAt(0) === '(' && _s.charAt(_s.length - 1) === ')') {
            sellerCount = _s.slice(1, _s.length - 1);
          } else {
            var _v = parseFloat(_s);
            if (_v >= 0 && _v <= 5) sellerRating = _s;
          }
          _j--;
        }
        if (_j >= 0 && !_LABEL.test(_lines[_j]) && _lines[_j].length < 40
            && _hasLetters(_lines[_j])) sellerName = _lines[_j];
      }

      // Item pages — and only item pages — publish an approximate point for the
      // listing itself. Mobile embeds it in the static map image URL
      // (`static_map.php?...&center=37.735290527344%2C-122.39318847656&zoom=11`),
      // web in embedded JSON. The two agree to the last digit for the same
      // listing, so this is Facebook's own published point, not anything derived
      // on the client. It is deliberately fuzzed — "Location is approximate" —
      // but it beats a city centroid by kilometres.
      function _validPair(lat, lng) {
        var a = parseFloat(lat), b = parseFloat(lng);
        if (isNaN(a) || isNaN(b)) return null;
        if (a < -90 || a > 90 || b < -180 || b > 180) return null;
        if (a === 0 && b === 0) return null;   // null island is a parse failure
        return {lat: String(a), lng: String(b)};
      }
      function _coordFromMapURL() {
        var src = null, imgs = document.querySelectorAll('img');
        for (var _c = 0; _c < imgs.length; _c++) {
          var _s = imgs[_c].getAttribute('src') || '';
          if (_s.indexOf('static_map') !== -1) { src = _s; break; }
        }
        // The rendered <img> is preferred: its src is already unescaped. Falling
        // back to raw markup catches the case where the map hasn't painted yet,
        // where '&' arrives as '&amp;' — splitting on '&' still terminates.
        if (!src) {
          var html = document.documentElement.outerHTML;
          var mi = html.indexOf('static_map');
          if (mi === -1) return null;
          src = html.slice(mi, mi + 400);
        }
        var ci = src.indexOf('center=');
        if (ci === -1) return null;
        var parts = decodeURIComponent(src.slice(ci + 7).split('&')[0]).split(',');
        return parts.length === 2 ? _validPair(parts[0], parts[1]) : null;
      }
      function _coordFromJSON() {
        var html = document.documentElement.outerHTML;
        var lats = html.match(/"latitude":\\s*-?\\d+\\.\\d+/g) || [];
        var lngs = html.match(/"longitude":\\s*-?\\d+\\.\\d+/g) || [];
        // A hit in raw markup is not a hit on *this* listing — item pages carry
        // "Today's picks" cards belonging to other sellers. Accept the pair only
        // when the page names exactly one, which is the same guard that stopped
        // a neighbour's condition being attributed here.
        function _uniq(a) {
          var m = {}; for (var _u = 0; _u < a.length; _u++) m[a[_u]] = 1;
          return Object.keys(m);
        }
        var uLat = _uniq(lats), uLng = _uniq(lngs);
        if (uLat.length !== 1 || uLng.length !== 1) return null;
        return _validPair(uLat[0].split(':')[1], uLng[0].split(':')[1]);
      }
      var _coord = null;
      try { _coord = _coordFromMapURL() || _coordFromJSON(); } catch (e) { _coord = null; }

      // Delivery, from rendered text — mobile embeds no listing JSON at all
      // (docs/embedded-payload.md §5), so the phrasing is the only source here.
      // Safe to read from `mainText` specifically: that walk stops dead at the
      // first related-content heading, so it holds this listing's words and
      // not the picks rail's.
      var _delivery = null;
      var _ships = /Ships to you|Ships for [$]|Shipping available/i.test(mainText);
      var _pickup = /Local pickup|Pickup only|Pick up in person/i.test(mainText);
      if (_ships || _pickup) {
        _delivery = [];
        if (_ships) _delivery.push('SHIPPING_ONSITE');
        if (_pickup) _delivery.push('IN_PERSON');
      }

      var _p = location.pathname, _i = _p.indexOf('/item/');
      return JSON.stringify({
        itemId: _i === -1 ? null : _p.slice(_i + 6).split('/')[0],
        sellerName: sellerName,
        sellerJoined: sellerJoined,
        sellerRatingText: sellerRating,
        sellerRatingCount: sellerCount,
        description: description || null,
        photoURLs: photos.slice(0, 12),
        postedText: listed,
        conditionText: after('Condition'),
        deliveryTypes: _delivery,
        // Detail pages phrase this as "Listed 3 days ago in Berkeley, CA";
        // keep only the place itself so it can be geocoded and shown plainly.
        locationText: (function(){
          var m = mainText.match(/[A-Z][A-Za-z .'-]+,\\s*[A-Z]{2}/);
          if (!m) return null;
          return m[0].replace(/^.*?\\bin\\s+/i, '').trim();
        })(),
        // Strings, not numbers: the full precision is kept verbatim rather than
        // routed through JSON's number formatting. Spurious as geography, but
        // load-bearing as an identifier — two listings from one seller carry
        // byte-identical coordinates (docs/data-model.md).
        latitude: _coord ? _coord.lat : null,
        longitude: _coord ? _coord.lng : null,
        // A sign-in modal often overlays a page whose real content is still in
        // the DOM behind it, so a login prompt alone isn't a wall — it's only a
        // wall if it also cost us the content. Reporting it otherwise would
        // throw away a listing we successfully read and trip the backoff.
        loginWall: LOGIN_NOISE.test(document.body.innerText || '')
                   && !description && photos.length === 0,
        title: document.title
      });
    })()
    """
    }
}
