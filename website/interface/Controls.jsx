import { Button } from "@heroui/react/button";
import { useState } from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";

function ShowcaseButtons({ items, initial, translate, verticalArrows }) {
  const [active, setActive] = useState(initial);

  function select(index, focus = false) {
    for (const item of items) item.panel.hidden = item !== items[index];
    setActive(index);
    if (focus) document.getElementById(items[index].id)?.focus();
  }

  function navigate(event, index) {
    const key = event.key;
    let next;
    if (key === "Home") next = 0;
    if (key === "End") next = items.length - 1;
    if (key === "ArrowRight" || (verticalArrows && key === "ArrowDown"))
      next = (index + 1) % items.length;
    if (key === "ArrowLeft" || (verticalArrows && key === "ArrowUp"))
      next = (index + items.length - 1) % items.length;
    if (next === undefined) return;
    event.preventDefault();
    select(next, true);
  }

  return items.map((item, index) => {
    const label = translate?.(item.labelKey) || item.text;
    return (
      <Button
        key={item.id}
        onPress={() => select(index)}
        onKeyDown={(event) => navigate(event, index)}
        render={(props) => (
          <button
            {...props}
            {...item.data}
            id={item.id}
            className={item.className || undefined}
            type="button"
            role="tab"
            aria-controls={item.panel.id}
            aria-selected={active === index}
            tabIndex={active === index ? 0 : -1}
          />
        )}
      >
        {item.hasLabelSpan ? (
          <span data-i18n={item.labelKey}>{label}</span>
        ) : (
          label
        )}
      </Button>
    );
  });
}

// Keep the server-rendered panels, links and translated copy in place.
export function mountTabs(group, translate, verticalArrows = false) {
  const buttons = [...group.querySelectorAll(':scope > button[role="tab"]')];
  const items = buttons.map((button) => {
    const span = button.querySelector("span[data-i18n]");
    return {
      id: button.id,
      className: button.className,
      text: button.textContent.trim(),
      labelKey: span?.dataset.i18n ?? button.dataset.i18n,
      hasLabelSpan: Boolean(span),
      panel: document.getElementById(button.getAttribute("aria-controls")),
      data: Object.fromEntries(
        [...button.attributes]
          .filter((a) => a.name.startsWith("data-"))
          .map((a) => [a.name, a.value]),
      ),
    };
  });
  if (!items.length || items.some((item) => !item.panel)) return;
  const initial = Math.max(
    0,
    buttons.findIndex((b) => b.getAttribute("aria-selected") === "true"),
  );
  const focused = buttons.includes(document.activeElement)
    ? document.activeElement.id
    : null;
  const root = createRoot(group);
  flushSync(() =>
    root.render(
      <ShowcaseButtons
        items={items}
        initial={initial}
        translate={translate}
        verticalArrows={verticalArrows}
      />,
    ),
  );
  if (focused) document.getElementById(focused)?.focus({ preventScroll: true });
}
