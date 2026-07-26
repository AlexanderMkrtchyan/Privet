/* Privet PWA install helper — shared by /app/ and the landing page. */
(function (global) {
  'use strict';

  var STORAGE_DISMISS = 'privet_pwa_dismissed_v1';
  var deferred = null;
  var installed = false;

  function isStandalone() {
    try {
      if (global.matchMedia && global.matchMedia('(display-mode: standalone)').matches) {
        return true;
      }
      if (global.navigator && global.navigator.standalone === true) return true;
    } catch (_) {}
    return false;
  }

  function isIos() {
    var ua = (global.navigator && global.navigator.userAgent) || '';
    return /iPad|iPhone|iPod/.test(ua) ||
      (global.navigator.platform === 'MacIntel' && global.navigator.maxTouchPoints > 1);
  }

  function dismissed() {
    try {
      return global.localStorage.getItem(STORAGE_DISMISS) === '1';
    } catch (_) {
      return false;
    }
  }

  function setDismissed() {
    try {
      global.localStorage.setItem(STORAGE_DISMISS, '1');
    } catch (_) {}
  }

  function clearDismissed() {
    try {
      global.localStorage.removeItem(STORAGE_DISMISS);
    } catch (_) {}
  }

  function emit(name, detail) {
    try {
      global.dispatchEvent(new CustomEvent(name, { detail: detail || {} }));
    } catch (_) {}
  }

  function canPrompt() {
    return !!deferred && !installed && !isStandalone();
  }

  function refreshUi() {
    var bar = document.getElementById('pwa-install-bar');
    var btn = document.getElementById('pwa-install-btn');
    var iosHint = document.getElementById('pwa-ios-hint');
    var defaultHint = document.getElementById('pwa-default-hint');
    var landingBtns = document.querySelectorAll('[data-pwa-install]');

    if (isStandalone() || installed) {
      if (bar) bar.hidden = true;
      landingBtns.forEach(function (el) {
        el.hidden = true;
        el.setAttribute('aria-hidden', 'true');
      });
      emit('privet-pwa-state', { ready: false, installed: true });
      return;
    }

    var ready = canPrompt();
    var showIos = !ready && isIos() && !dismissed();

    if (bar) {
      // Always offer install until installed/dismissed — Chrome may delay
      // beforeinstallprompt; the button falls back to address-bar instructions.
      var showBar = !dismissed();
      bar.hidden = !showBar;
      if (iosHint) iosHint.hidden = !showIos;
      if (defaultHint) defaultHint.hidden = showIos;
      if (btn) {
        btn.hidden = false;
        btn.disabled = false;
        btn.textContent = ready ? 'Install' : (isIos() ? 'How to' : 'Install');
      }
    }

    landingBtns.forEach(function (el) {
      if (ready) {
        el.hidden = false;
        el.removeAttribute('aria-hidden');
        el.classList.add('is-ready');
        if (el.tagName === 'BUTTON' || el.getAttribute('role') === 'button') {
          el.disabled = false;
        }
      } else if (isIos()) {
        el.hidden = false;
        el.removeAttribute('aria-hidden');
        el.classList.add('is-ios');
      } else {
        // Keep landing CTA visible so users know PWA exists; click explains.
        el.hidden = false;
        el.removeAttribute('aria-hidden');
        el.classList.remove('is-ready');
      }
    });

    emit('privet-pwa-state', {
      ready: ready,
      ios: isIos(),
      installed: false,
    });
  }

  async function promptInstall() {
    if (!deferred) {
      if (isIos()) {
        alert(
          'To install Privet on iPhone/iPad:\n\n' +
            '1. Tap the Share button\n' +
            '2. Choose “Add to Home Screen”\n' +
            '3. Tap Add',
        );
        return { outcome: 'ios-instructions' };
      }
      alert(
        'Privet can be installed as an app from this browser.\n\n' +
          'Look for the install icon in the address bar, or open the browser menu and choose “Install Privet” / “Install app”.',
      );
      return { outcome: 'manual' };
    }

    var ev = deferred;
    deferred = null;
    ev.prompt();
    var choice = await ev.userChoice;
    if (choice && choice.outcome === 'accepted') {
      installed = true;
      setDismissed();
    }
    refreshUi();
    return choice || { outcome: 'dismissed' };
  }

  function dismissBar() {
    setDismissed();
    var bar = document.getElementById('pwa-install-bar');
    if (bar) bar.hidden = true;
  }

  async function registerServiceWorker() {
    if (!('serviceWorker' in navigator)) return null;
    try {
      var reg = await navigator.serviceWorker.register('/sw.js', { scope: '/' });
      return reg;
    } catch (e) {
      console.warn('Privet SW register failed', e);
      return null;
    }
  }

  function wireDom() {
    var btn = document.getElementById('pwa-install-btn');
    if (btn && !btn.__privetWired) {
      btn.__privetWired = true;
      btn.addEventListener('click', function (e) {
        e.preventDefault();
        promptInstall();
      });
    }
    var dismiss = document.getElementById('pwa-install-dismiss');
    if (dismiss && !dismiss.__privetWired) {
      dismiss.__privetWired = true;
      dismiss.addEventListener('click', function (e) {
        e.preventDefault();
        dismissBar();
      });
    }
    document.querySelectorAll('[data-pwa-install]').forEach(function (el) {
      if (el.__privetWired) return;
      el.__privetWired = true;
      el.addEventListener('click', function (e) {
        e.preventDefault();
        promptInstall();
      });
    });
  }

  function boot() {
    if (isStandalone()) {
      installed = true;
      refreshUi();
      return;
    }

    global.addEventListener('beforeinstallprompt', function (e) {
      e.preventDefault();
      deferred = e;
      clearDismissed();
      refreshUi();
    });

    global.addEventListener('appinstalled', function () {
      installed = true;
      deferred = null;
      setDismissed();
      refreshUi();
    });

    registerServiceWorker().then(function () {
      wireDom();
      refreshUi();
    });

    // Flutter may inject DOM later; re-wire once.
    global.setTimeout(function () {
      wireDom();
      refreshUi();
    }, 800);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }

  global.PrivetPwa = {
    promptInstall: promptInstall,
    canPrompt: canPrompt,
    isStandalone: isStandalone,
    dismissBar: dismissBar,
  };
})(window);
