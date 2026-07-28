import Foundation

/// Renderer payload adapted from the target-validation, DOM-layout, bridge,
/// and cleanup patterns in lencx/opsail's `opsail-refit-codex` crate.
///
/// Opsail is Apache-2.0 licensed. See THIRD_PARTY_NOTICES.md for attribution.
enum CodexSidebarQuotaRenderer {
    static func evaluateRequest(id: Int) -> [String: Any] {
        [
            "id": id,
            "method": "Runtime.evaluate",
            "params": [
                "expression": source,
                "awaitPromise": true,
                "returnByValue": true,
                "userGesture": false
            ]
        ]
    }

    static let cleanupExpression = """
    (() => {
      window.__quotaMonitorCodexSidebarQuota?.cleanup?.();
      return true;
    })()
    """

    // Keep this self-contained: CDP installs it directly into the validated
    // renderer, without modifying ChatGPT.app or loading remote assets.
    static let source = #"""
    (() => {
      "use strict";
      const STATE_KEY = "__quotaMonitorCodexSidebarQuota";
      const HOST_ID = "quota-monitor-codex-sidebar";
      const STYLE_ID = `${HOST_ID}-style`;
      const DETAILS_ID = `${HOST_ID}-details`;
      const SIDEBAR_SELECTOR =
        "aside.app-shell-left-panel, aside[data-testid='app-shell-floating-left-panel']";
      const SHELL_SELECTOR = "main.main-surface";
      const REQUEST_PREFIX = "quota-monitor-rate-limits";
      const REFRESH_MS = 15 * 60 * 1000;

      window[STATE_KEY]?.cleanup?.();

      const css = `
      #${HOST_ID} {
        box-sizing: border-box;
        display: block;
        flex: 0 1 auto;
        min-width: 42px;
        max-width: min(112px, 42%);
        color: var(--color-token-foreground, var(--color-text-foreground, currentColor));
        cursor: default;
        font: inherit;
        outline: none;
      }
      #${HOST_ID}[hidden], .qm-codex-quota-row[hidden] { display: none !important; }
      .qm-codex-quota-summary {
        box-sizing: border-box;
        max-width: 100%;
        padding: 2px 8px;
        overflow: hidden;
        border: 1px solid var(--color-token-border-light, var(--color-border-light, currentColor));
        border-radius: 999px;
        background: var(--color-token-list-hover-background, var(--color-background-button-tertiary, transparent));
        color: var(--color-token-text-secondary, var(--color-text-foreground-secondary, currentColor));
        font-size: 10px;
        font-variant-numeric: tabular-nums;
        font-weight: 550;
        line-height: 16px;
        text-overflow: ellipsis;
        white-space: nowrap;
      }
      #${HOST_ID}:focus-visible .qm-codex-quota-summary {
        outline: 1px solid var(--color-token-focus-ring, var(--color-token-interactive-label-accent-default, currentColor));
        outline-offset: 2px;
      }
      #${HOST_ID}[data-stale="true"] .qm-codex-quota-summary { border-style: dashed; }
      #${DETAILS_ID} {
        box-sizing: border-box;
        position: fixed;
        z-index: 1000;
        display: none;
        width: 240px;
        max-width: calc(100vw - 32px);
        max-height: calc(100vh - 16px);
        padding: 8px;
        overflow-y: auto;
        border: 1px solid var(--color-token-border-default, var(--color-border, currentColor));
        border-radius: 8px;
        background: var(--color-token-side-bar-background, var(--color-background-surface, Canvas));
        box-shadow: var(--elevation-sidebar, 0 8px 24px rgb(0 0 0 / 20%));
        color: var(--color-token-foreground, var(--color-text-foreground, CanvasText));
        font: inherit;
        font-size: 10px;
        line-height: 14px;
      }
      #${DETAILS_ID}[data-open="true"] { display: grid; gap: 8px; }
      .qm-codex-quota-stale {
        color: var(--color-token-description-foreground, var(--color-text-foreground-tertiary, currentColor));
      }
      .qm-codex-quota-row { display: grid; gap: 4px; }
      .qm-codex-quota-row + .qm-codex-quota-row {
        padding-top: 8px;
        border-top: 1px solid var(--color-token-border-light, var(--color-border-light, currentColor));
      }
      .qm-codex-quota-credits {
        display: grid;
        gap: 4px;
        padding-top: 8px;
        border-top: 1px solid var(--color-token-border-light, var(--color-border-light, currentColor));
      }
      .qm-codex-quota-credits b { font-weight: 600; }
      .qm-codex-quota-credit {
        display: flex;
        justify-content: space-between;
        gap: 8px;
        color: var(--color-token-description-foreground, var(--color-text-foreground-tertiary, currentColor));
        font-variant-numeric: tabular-nums;
      }
      .qm-codex-quota-line {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 8px;
        color: var(--color-token-text-secondary, var(--color-text-foreground-secondary, currentColor));
      }
      .qm-codex-quota-line b {
        color: var(--color-token-foreground, var(--color-text-foreground, currentColor));
        font-variant-numeric: tabular-nums;
        font-weight: 600;
      }
      .qm-codex-quota-meta {
        color: var(--color-token-description-foreground, var(--color-text-foreground-tertiary, currentColor));
        white-space: pre-line;
      }
      .qm-codex-quota-track {
        position: relative;
        height: 3px;
        overflow: hidden;
        border-radius: 999px;
        background: var(--color-token-list-hover-background, var(--color-background-button-tertiary, transparent));
      }
      .qm-codex-quota-track > i {
        position: absolute;
        inset: 0 auto 0 0;
        width: var(--quota-remaining, 0%);
        border-radius: inherit;
        background: var(--color-token-interactive-label-accent-default, var(--color-token-primary, currentColor));
        transition: width 180ms ease-out;
      }
      @media (prefers-reduced-motion: reduce) {
        .qm-codex-quota-track > i { transition: none; }
      }`;

      const state = {
        host: null,
        details: null,
        sidebar: null,
        row: null,
        snapshot: null,
        resetCredits: [],
        stale: false,
        open: false,
        requestId: null,
        listeners: [],
        mutationObserver: null,
        resizeObserver: null,
        refreshTimer: null,
        layoutFrame: null,
        closeTimer: null,
        disposed: false,
      };

      const listen = (target, type, handler, options) => {
        target.addEventListener(type, handler, options);
        state.listeners.push(() => target.removeEventListener(type, handler, options));
      };
      const language = () => String(
        document.documentElement?.lang || navigator.language || "en"
      ).toLowerCase();
      const zh = () => language().startsWith("zh");
      const copy = () => zh()
        ? { five: "5 小时", week: "每周", left: "剩余", used: "已用",
            reset: "重置于", stale: "数据暂未刷新", unavailable: "暂未取得额度",
            credits: "额度重置券", expires: "后到期" }
        : { five: "5 hours", week: "weekly", left: "remaining", used: "used",
            reset: "Resets", stale: "Data may be stale", unavailable: "Usage unavailable",
            credits: "Limit reset credits", expires: "until expiry" };
      const make = (tag, className) => {
        const element = document.createElement(tag);
        if (className) element.className = className;
        return element;
      };
      const rect = (element) => {
        try {
          const value = element?.getBoundingClientRect?.();
          const values = value
            ? [value.left, value.top, value.right, value.bottom, value.width, value.height]
                .map(Number)
            : [];
          if (values.length !== 6 || !values.every(Number.isFinite)) {
            return null;
          }
          return {
            left: values[0], top: values[1], right: values[2], bottom: values[3],
            width: values[4], height: values[5],
            centerX: values[0] + values[4] / 2,
            centerY: values[1] + values[5] / 2,
          };
        } catch { return null; }
      };
      const rects = (root, selector) => {
        try {
          return [...(root?.querySelectorAll?.(selector) || [])]
            .map(element => ({ element, rect: rect(element) }))
            .filter(entry => entry.rect);
        } catch { return []; }
      };
      const directChild = (ancestor, descendant) => {
        let current = descendant;
        while (current?.parentElement && current.parentElement !== ancestor) {
          current = current.parentElement;
        }
        return current?.parentElement === ancestor ? current : null;
      };
      const commonAncestor = (left, right) => {
        const ancestors = new Set();
        for (let current = left; current; current = current.parentElement) ancestors.add(current);
        for (let current = right; current; current = current.parentElement) {
          if (ancestors.has(current)) return current;
        }
        return null;
      };
      const findAccountLayout = (sidebar) => {
        const sidebarRect = rect(sidebar);
        if (!sidebarRect) return null;
        const footerTop = sidebarRect.bottom - Math.min(112, sidebarRect.height * 0.3);
        const avatars = rects(
          sidebar,
          "img, [data-testid*='avatar' i], [class*='avatar' i]"
        ).filter(entry => entry.rect.width >= 16 && entry.rect.width <= 48
            && entry.rect.height >= 16 && entry.rect.height <= 48
            && Math.abs(entry.rect.width - entry.rect.height) <= 8
            && entry.rect.centerY >= footerTop
            && entry.rect.centerY <= sidebarRect.bottom
            && entry.rect.centerX >= sidebarRect.left
            && entry.rect.centerX <= sidebarRect.left + sidebarRect.width * 0.55)
          .sort((a, b) => b.rect.centerY - a.rect.centerY);
        const avatar = avatars[0] || null;
        const account = avatar?.element?.closest?.("button, [role='button'], a");
        const accountRect = rect(account);
        if (!account || !accountRect) return null;
        const actions = rects(sidebar, "button, [role='button']")
          .filter(entry => entry.rect.width >= 20 && entry.rect.width <= 48
            && entry.rect.height >= 20 && entry.rect.height <= 48
            && entry.rect.centerY >= footerTop
            && entry.rect.centerY <= sidebarRect.bottom
            && entry.rect.centerX >= sidebarRect.left + sidebarRect.width * 0.5
            && entry.rect.centerX <= sidebarRect.right)
          .sort((a, b) =>
            Math.abs(a.rect.centerY - avatar.rect.centerY)
              - Math.abs(b.rect.centerY - avatar.rect.centerY)
            || b.rect.width * b.rect.height - a.rect.width * a.rect.height
            || b.rect.centerX - a.rect.centerX
          );
        for (const action of actions) {
          const row = commonAncestor(account, action.element);
          const accountSlot = directChild(row, account);
          const trailingSlot = directChild(row, action.element);
          const rowRect = rect(row);
          if (row && row !== sidebar && accountSlot && trailingSlot
              && accountSlot !== trailingSlot && rowRect
              && rowRect.width >= 120 && rowRect.height >= 28 && rowRect.height <= 72
              && Math.abs(avatar.rect.centerY - action.rect.centerY) <= 16) {
            return { row, trailingSlot };
          }
        }
        return null;
      };
      const durationLabel = (minutes) => {
        const text = copy();
        if (Math.abs(Number(minutes) - 300) <= 15) return text.five;
        if (Math.abs(Number(minutes) - 10080) <= 504) return text.week;
        return Number(minutes) >= 60
          ? `${Math.round(Number(minutes) / 60)}h`
          : `${Math.round(Number(minutes) || 0)}m`;
      };
      const windows = () => [state.snapshot?.primary, state.snapshot?.secondary]
        .filter(item => item && Number.isFinite(item.usedPercent))
        .sort((a, b) => (a.windowDurationMins || Infinity) - (b.windowDurationMins || Infinity))
        .map(item => ({
          label: durationLabel(item.windowDurationMins),
          used: Math.round(Math.max(0, Math.min(100, item.usedPercent))),
          remaining: Math.round(100 - Math.max(0, Math.min(100, item.usedPercent))),
          resetsAt: Number(item.resetsAt) || null,
        }));
      const resetCredits = value => Array.isArray(value?.credits)
        ? value.credits
          .filter(credit => credit?.status === "available"
            && Number.isFinite(credit.expiresAt)
            && credit.expiresAt * 1000 > Date.now())
          .sort((a, b) => a.expiresAt - b.expiresAt)
        : [];
      const formatReset = (seconds) => {
        if (!seconds) return "";
        const date = new Date(seconds * 1000);
        const remaining = Math.max(0, date.getTime() - Date.now());
        const hours = Math.floor(remaining / 3600000);
        const minutes = Math.floor((remaining % 3600000) / 60000);
        const countdown = hours >= 24
          ? `${Math.floor(hours / 24)}d ${hours % 24}h`
          : `${hours}h ${minutes}m`;
        return `${countdown}\n${new Intl.DateTimeFormat(undefined, {
          year: "numeric", month: "2-digit", day: "2-digit",
          hour: "2-digit", minute: "2-digit", second: "2-digit",
          hourCycle: "h23",
        }).format(date)}`;
      };
      const positionDetails = () => {
        if (!state.open) return;
        const anchor = rect(state.host);
        const tooltip = rect(state.details);
        if (!anchor || !tooltip) return;
        const left = Math.max(16, Math.min(
          window.innerWidth - tooltip.width - 16,
          anchor.right - tooltip.width
        ));
        const above = anchor.top - tooltip.height - 8;
        const top = above >= 8 ? above : Math.min(
          window.innerHeight - tooltip.height - 8,
          anchor.bottom + 8
        );
        Object.assign(state.details.style, {
          left: `${Math.round(left)}px`,
          top: `${Math.round(Math.max(8, top))}px`,
        });
      };
      const render = () => {
        if (!state.host || !state.details) return;
        const values = windows();
        const text = copy();
        state.host.hidden = values.length === 0 || !state.row?.isConnected;
        state.host.dataset.stale = String(state.stale);
        state.host.querySelector(".qm-codex-quota-summary").textContent =
          values.map(value => `${value.label} ${value.remaining}%`).join(" / ");
        const content = state.details.querySelector(".qm-codex-quota-content");
        content.replaceChildren();
        if (state.stale) {
          const stale = make("div", "qm-codex-quota-stale");
          stale.textContent = text.stale;
          content.append(stale);
        }
        for (const value of values) {
          const row = make("section", "qm-codex-quota-row");
          const line = make("div", "qm-codex-quota-line");
          const label = make("span");
          label.textContent = value.label;
          const remaining = make("b");
          remaining.textContent = `${value.remaining}% ${text.left}`;
          line.append(label, remaining);
          const meta = make("div", "qm-codex-quota-meta");
          meta.textContent = `${value.used}% ${text.used}`
            + (value.resetsAt ? `\n${text.reset} ${formatReset(value.resetsAt)}` : "");
          const track = make("div", "qm-codex-quota-track");
          track.setAttribute("role", "progressbar");
          track.setAttribute("aria-valuemin", "0");
          track.setAttribute("aria-valuemax", "100");
          track.setAttribute("aria-valuenow", String(value.remaining));
          track.style.setProperty("--quota-remaining", `${value.remaining}%`);
          track.append(make("i"));
          row.append(line, meta, track);
          content.append(row);
        }
        if (state.resetCredits.length > 0) {
          const credits = make("section", "qm-codex-quota-credits");
          const title = make("b");
          title.textContent = text.credits;
          credits.append(title);
          for (const [index, credit] of state.resetCredits.entries()) {
            const line = make("div", "qm-codex-quota-credit");
            const label = make("span");
            label.textContent = `#${index + 1}`;
            const expiry = make("span");
            expiry.textContent = `${formatReset(credit.expiresAt).split("\n")[0]} ${text.expires}`;
            line.append(label, expiry);
            credits.append(line);
          }
          content.append(credits);
        }
        state.host.setAttribute("aria-label", values.map(
          value => `${value.label} ${value.remaining}% ${text.left}`
        ).join(", ") || text.unavailable);
        positionDetails();
      };
      const open = () => {
        if (state.host?.hidden) return;
        clearTimeout(state.closeTimer);
        state.open = true;
        state.details.dataset.open = "true";
        state.details.setAttribute("aria-hidden", "false");
        render();
        requestAnimationFrame(positionDetails);
      };
      const close = () => {
        state.open = false;
        state.details.dataset.open = "false";
        state.details.setAttribute("aria-hidden", "true");
      };
      const scheduleClose = () => {
        clearTimeout(state.closeTimer);
        state.closeTimer = setTimeout(close, 80);
      };
      const ensureUI = () => {
        let style = document.getElementById(STYLE_ID);
        if (!style) {
          style = make("style");
          style.id = STYLE_ID;
          (document.head || document.documentElement).append(style);
        }
        style.textContent = css;
        const host = make("div");
        host.id = HOST_ID;
        host.tabIndex = 0;
        host.hidden = true;
        host.append(make("div", "qm-codex-quota-summary"));
        const details = make("aside");
        details.id = DETAILS_ID;
        details.dataset.open = "false";
        details.setAttribute("role", "tooltip");
        details.setAttribute("aria-hidden", "true");
        details.append(make("div", "qm-codex-quota-content"));
        (document.body || document.documentElement).append(host, details);
        listen(host, "pointerenter", open);
        listen(host, "pointerleave", scheduleClose);
        listen(host, "focusin", open);
        listen(host, "focusout", scheduleClose);
        listen(details, "pointerenter", open);
        listen(details, "pointerleave", scheduleClose);
        state.host = host;
        state.details = details;
      };
      const layout = () => {
        state.layoutFrame = null;
        const sidebar = document.querySelector(SIDEBAR_SELECTOR);
        const shell = document.querySelector(SHELL_SELECTOR);
        if (!sidebar || !shell || !window.electronBridge?.sendMessageFromView) {
          state.host.hidden = true;
          close();
          return;
        }
        state.sidebar = sidebar;
        const measured = findAccountLayout(sidebar);
        if (!measured) {
          state.row = null;
          state.host.hidden = true;
          close();
          return;
        }
        state.row = measured.row;
        if (state.host.parentElement !== measured.row
            || state.host.nextElementSibling !== measured.trailingSlot) {
          measured.row.insertBefore(state.host, measured.trailingSlot);
        }
        if (typeof ResizeObserver === "function") {
          state.resizeObserver?.disconnect();
          state.resizeObserver = new ResizeObserver(scheduleLayout);
          state.resizeObserver.observe(sidebar);
          state.resizeObserver.observe(measured.row);
        }
        render();
      };
      const scheduleLayout = () => {
        if (state.layoutFrame !== null) return;
        state.layoutFrame = requestAnimationFrame(layout);
      };
      const sendRead = () => {
        if (!window.electronBridge?.sendMessageFromView || state.requestId) return;
        state.requestId = `${REQUEST_PREFIX}-${Date.now()}-${Math.random().toString(16).slice(2)}`;
        try {
          window.electronBridge.sendMessageFromView({
            type: "mcp-request",
            hostId: HOST_ID,
            request: { id: state.requestId, method: "account/rateLimits/read" },
          });
        } catch {
          state.requestId = null;
          state.stale = Boolean(state.snapshot);
          render();
        }
      };
      const onMessage = event => {
        const payload = event?.data;
        if (!payload || payload.hostId !== HOST_ID) return;
        if (payload.type === "mcp-response"
            && String(payload.message?.id || "") === state.requestId) {
          state.requestId = null;
          if (payload.message?.error || !payload.message?.result?.rateLimits) {
            state.stale = Boolean(state.snapshot);
          } else {
            state.snapshot = payload.message.result.rateLimits;
            state.resetCredits = resetCredits(
              payload.message.result.rateLimitResetCredits);
            state.stale = false;
          }
          render();
          return;
        }
        if (payload.type === "mcp-notification"
            && payload.method === "account/rateLimits/updated"
            && payload.params) {
          if (payload.params.rateLimits) {
            state.snapshot = { ...(state.snapshot || {}), ...payload.params.rateLimits };
          }
          if (payload.params.rateLimitResetCredits) {
            state.resetCredits = resetCredits(payload.params.rateLimitResetCredits);
          }
          state.stale = false;
          render();
          setTimeout(sendRead, 1200);
        }
      };
      const mutationRelevant = mutation => [...mutation.addedNodes, ...mutation.removedNodes]
        .some(node => node?.nodeType === 1 && (
          node.matches?.(SIDEBAR_SELECTOR)
          || node.querySelector?.(SIDEBAR_SELECTOR)
          || node.matches?.("img, button, [role='button']")
          || node.querySelector?.("img, button, [role='button']")
        ));
      const cleanup = () => {
        if (state.disposed) return true;
        state.disposed = true;
        clearInterval(state.refreshTimer);
        clearTimeout(state.closeTimer);
        if (state.layoutFrame !== null) cancelAnimationFrame(state.layoutFrame);
        state.mutationObserver?.disconnect();
        state.resizeObserver?.disconnect();
        for (const remove of state.listeners.splice(0)) remove();
        state.details?.remove();
        state.host?.remove();
        document.getElementById(STYLE_ID)?.remove();
        delete window[STATE_KEY];
        return true;
      };

      ensureUI();
      listen(window, "message", onMessage);
      listen(window, "focus", () => { sendRead(); scheduleLayout(); });
      listen(window, "resize", () => { scheduleLayout(); positionDetails(); });
      if (typeof MutationObserver === "function") {
        state.mutationObserver = new MutationObserver(mutations => {
          if (mutations.some(mutationRelevant)) scheduleLayout();
        });
        state.mutationObserver.observe(document.body || document.documentElement, {
          childList: true,
          subtree: true,
        });
      }
      state.refreshTimer = setInterval(() => {
        if (document.visibilityState !== "hidden") sendRead();
      }, REFRESH_MS);
      window[STATE_KEY] = {
        cleanup,
        diagnostics: () => ({
          installed: true,
          visible: Boolean(state.host?.isConnected && !state.host.hidden),
          stale: state.stale,
          windowCount: windows().length,
        }),
      };
      scheduleLayout();
      sendRead();
      return window[STATE_KEY].diagnostics();
    })()
    """#
}
