import React, { useEffect, useRef, useState } from "react";
import { Button } from "@heroui/react/button";
import { Tabs } from "@heroui/react/tabs";
import { Chip } from "@heroui/react/chip";
import { Accordion } from "@heroui/react/accordion";
import { Dropdown } from "@heroui/react/dropdown";
import { Modal } from "@heroui/react/modal";
import { cva } from "class-variance-authority";
import { clsx } from "clsx";
import { twMerge } from "tailwind-merge";
import { animate } from "motion/mini";
import { Toaster, toast } from "sonner";
import {
  ArrowDownToLine,
  ArrowRight,
  ArrowUpRight,
  Check,
  ChevronDown,
  Copy,
  Maximize2,
  Menu as MenuIcon,
  X,
} from "lucide-react";

const button = cva(
  "pi-action pi:inline-flex pi:items-center pi:justify-center pi:gap-2",
  {
    variants: {
      tone: { primary: "pi-primary", quiet: "pi-quiet", ghost: "pi-ghost" },
    },
    defaultVariants: { tone: "primary" },
  },
);
export const cn = (...values) => twMerge(clsx(values));
export function useLanguage(initial) {
  const [lang, setLang] = useState(initial);
  useEffect(() => {
    const update = () =>
      setLang(
        document.documentElement.lang.toLowerCase().startsWith("en")
          ? "en"
          : "zh",
      );
    update();
    const observer = new MutationObserver(update);
    observer.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["lang"],
    });
    return () => observer.disconnect();
  }, []);
  return lang;
}
export const tx = (value, lang) =>
  typeof value === "string" ? value : (value?.[lang] ?? value?.zh ?? "");
export function Mark({ Icon, children }) {
  return (
    <Chip className="pi-mark" size="sm">
      {Icon && <Icon size={15} aria-hidden="true" />}
      <Chip.Label>{children}</Chip.Label>
    </Chip>
  );
}
export function Action({
  href,
  onPress,
  children,
  tone = "primary",
  icon,
  className,
  ...props
}) {
  const Icon = icon || (href?.startsWith("#") ? ArrowRight : ArrowUpRight);
  const inner = (
    <>
      {children}
      <Icon size={17} aria-hidden="true" />
    </>
  );
  return href ? (
    <a href={href} className={cn(button({ tone }), className)} {...props}>
      {inner}
    </a>
  ) : (
    <Button
      onPress={onPress}
      className={cn(button({ tone }), className)}
      {...props}
    >
      {inner}
    </Button>
  );
}
export function CopyAction({ text, label, lang = "zh" }) {
  const [copied, setCopied] = useState(false);
  useEffect(() => {
    if (copied) {
      const t = setTimeout(() => setCopied(false), 1900);
      return () => clearTimeout(t);
    }
  }, [copied]);
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
      toast.success(lang === "en" ? "Copied to clipboard" : "已复制到剪贴板");
    } catch {
      toast.error(
        lang === "en"
          ? "Select the command and copy it manually."
          : "请选中命令后手动复制",
      );
    }
  };
  return (
    <div className="pi-command">
      <code tabIndex={0}>{text}</code>
      <Button className="pi-icon-button" aria-label={label} onPress={copy}>
        {copied ? <Check size={17} /> : <Copy size={17} />}
      </Button>
    </div>
  );
}
export function Header({ site, lang }) {
  const links = site.nav.map(([name, href]) => [
    name,
    href.startsWith("#") ? "/" + href : href,
  ]);
  const toggleLanguage = () =>
    document.dispatchEvent(
      new CustomEvent("product-language", {
        detail: lang === "en" ? "zh" : "en",
      }),
    );
  return (
    <header className="pi-header pi-scoped">
      <div className="pi-container pi-header-row">
        <div className="pi-identity">
          <a className="pi-publisher" href="https://timmyagentic.si/">
            timmyagentic
          </a>
          <span aria-hidden="true">/</span>
          <a className="pi-brand" href="/">
            {site.name}
          </a>
        </div>
        <nav
          className="pi-desktop-nav"
          aria-label={lang === "en" ? "Primary navigation" : "主导航"}
        >
          {links.map(([label, href]) => (
            <a key={href} href={href}>
              {tx(label, lang)}
            </a>
          ))}
        </nav>
        <div className="pi-nav-end">
          {site.bilingual && (
            <Button
              onPress={toggleLanguage}
              className="pi-lang"
              aria-label={
                lang === "en" ? "切换为简体中文" : "Switch to English"
              }
            >
              {lang === "en" ? "中文" : "EN"}
            </Button>
          )}
          <Dropdown>
            <Dropdown.Trigger
              className="pi-mobile-toggle"
              aria-label={lang === "en" ? "Open navigation" : "打开导航"}
            >
              <MenuIcon size={21} />
            </Dropdown.Trigger>
            <Dropdown.Popover
              className="pi-nav-menu"
              placement="bottom end"
              offset={7}
            >
              <Dropdown.Menu
                aria-label={lang === "en" ? "Site navigation" : "站点导航"}
              >
                {links.map(([label, href]) => (
                  <Dropdown.Item
                    id={href}
                    textValue={tx(label, lang)}
                    href={href}
                    key={href}
                  >
                    {tx(label, lang)}
                    <ArrowUpRight size={15} aria-hidden="true" />
                  </Dropdown.Item>
                ))}
              </Dropdown.Menu>
            </Dropdown.Popover>
          </Dropdown>
        </div>
      </div>
    </header>
  );
}
export function HeroCopy({
  title,
  description,
  children,
  mark,
  id = "hero-title",
}) {
  return (
    <div className="pi-copy">
      {mark}
      <h1 id={id}>{title}</h1>
      <p className="pi-lead">{description}</p>
      {children}
    </div>
  );
}
export function Choices({
  label,
  tabs,
  value,
  onChange,
  children,
  keepPanels = false,
}) {
  const container = useRef(null);
  const previous = useRef(value);
  useEffect(() => {
    if (previous.current === value) return;
    previous.current = value;
    const panel = container.current?.querySelector('[role="tabpanel"]');
    if (panel && !matchMedia("(prefers-reduced-motion: reduce)").matches) {
      const transition = animate(
        panel,
        { opacity: [0.64, 1] },
        { duration: 0.15 },
      );
      return () => transition.stop();
    }
  }, [value]);
  return (
    <div ref={container}>
      <Tabs
        selectedKey={value}
        onSelectionChange={(key) => onChange(String(key))}
        className="pi-tabs"
      >
        <div className="pi-tabs-shell">
          <Tabs.List aria-label={label} className="pi-tab-list" items={tabs}>
            {(item) => (
              <Tabs.Tab key={item.id} id={item.id} className="pi-tab">
                {item.icon && <item.icon size={16} aria-hidden="true" />}
                {item.label}
                <Tabs.Indicator className="pi-tab-indicator" />
              </Tabs.Tab>
            )}
          </Tabs.List>
        </div>
        {tabs.map((item) => (
          <Tabs.Panel
            key={item.id}
            id={item.id}
            shouldForceMount={keepPanels}
            data-product-panel={item.id}
            hidden={keepPanels && value !== item.id}
            className="pi-tab-panel"
          >
            {keepPanels || value === item.id
              ? children(item, value === item.id)
              : null}
          </Tabs.Panel>
        ))}
      </Tabs>
    </div>
  );
}
export function ModalPanel({
  open,
  onChange,
  title,
  closeLabel = "关闭",
  className,
  returnFocus,
  children,
}) {
  const change = (next) => {
    onChange(next);
    if (!next)
      requestAnimationFrame(() =>
        returnFocus?.current?.focus({ preventScroll: true }),
      );
  };
  return (
    <Modal.Backdrop
      isOpen={open}
      onOpenChange={change}
      isDismissable
      className="pi-modal-backdrop"
    >
      <Modal.Container className="pi-modal-container">
        <Modal.Dialog className={className}>
          <div className="pi-dialog-bar">
            <Modal.Heading>{title}</Modal.Heading>
            <Button
              className="pi-icon-button"
              aria-label={closeLabel}
              onPress={() => change(false)}
            >
              <X size={20} />
            </Button>
          </div>
          {children}
        </Modal.Dialog>
      </Modal.Container>
    </Modal.Backdrop>
  );
}
export function Figure({
  src,
  alt,
  width,
  height,
  title,
  lang = "zh",
  className = "",
  original = src,
  priority = false,
  altKey,
}) {
  const [open, setOpen] = useState(false),
    [zoom, setZoom] = useState(false);
  const trigger = useRef(null);
  return (
    <>
      <div className={cn("pi-figure", className)}>
        <a
          ref={trigger}
          href={original}
          aria-haspopup="dialog"
          aria-label={(lang === "en" ? "View image: " : "放大查看 ") + title}
          onClick={(event) => {
            if (
              event.button !== 0 ||
              event.metaKey ||
              event.ctrlKey ||
              event.shiftKey ||
              event.altKey
            )
              return;
            event.preventDefault();
            setZoom(false);
            setOpen(true);
          }}
        >
          <img
            src={src}
            width={width}
            height={height}
            alt={alt}
            data-i18n-alt={altKey}
            loading={priority ? "eager" : "lazy"}
            decoding="async"
          />
          <span className="pi-enlarge" aria-hidden="true">
            <Maximize2 size={16} />
          </span>
        </a>
      </div>
      <ModalPanel
        open={open}
        onChange={setOpen}
        title={title}
        closeLabel={lang === "en" ? "Close image" : "关闭大图"}
        returnFocus={trigger}
        className="pi-image-dialog"
      >
        <div
          className={cn("pi-dialog-stage", zoom && "pi-zoomed")}
          tabIndex={0}
        >
          <img src={original} alt={alt} />
        </div>
        <div className="pi-dialog-foot">
          <Button
            className="pi-small-button"
            onPress={() => setZoom(!zoom)}
            aria-pressed={zoom}
          >
            {zoom
              ? lang === "en"
                ? "Fit to window"
                : "适应窗口"
              : lang === "en"
                ? "Actual size"
                : "查看原尺寸"}
          </Button>
          <a href={original} target="_blank" rel="noopener">
            {lang === "en" ? "Open original" : "打开原图"}{" "}
            <ArrowUpRight size={15} />
          </a>
        </div>
      </ModalPanel>
    </>
  );
}
export function FAQ({ items, lang }) {
  return (
    <Accordion
      allowsMultipleExpanded
      className="pi-faq"
      aria-label={lang === "en" ? "Frequently asked questions" : "常见问题"}
    >
      {items.map((item, i) => (
        <Accordion.Item key={i} id={"q" + i} className="pi-faq-item">
          <Accordion.Heading level={3}>
            <Accordion.Trigger className="pi-faq-trigger">
              {tx(item.question, lang)}
              <ChevronDown size={18} aria-hidden="true" />
            </Accordion.Trigger>
          </Accordion.Heading>
          <Accordion.Panel className="pi-faq-answer">
            <Accordion.Body>
              <div
                dangerouslySetInnerHTML={{ __html: tx(item.answer, lang) }}
              />
            </Accordion.Body>
          </Accordion.Panel>
        </Accordion.Item>
      ))}
    </Accordion>
  );
}
export function Notifications({ lang }) {
  return (
    <Toaster
      position="bottom-center"
      visibleToasts={2}
      toastOptions={{ className: "pi-toast" }}
      closeButton
      label={lang === "en" ? "Notifications" : "操作提示"}
    />
  );
}
export { ArrowRight, ArrowUpRight, ArrowDownToLine };
