import React, { useState } from "react";
import { Activity, History, ListTree, Download } from "lucide-react";
import { Action, Choices, Figure } from "./ui.jsx";
import { copy } from "./copy.mjs";
export const site = {
  name: "Quota Monitor",
  lang: "en",
  bilingual: true,
  nav: [
    [{ zh: "功能", en: "Features" }, "#features"],
    [{ zh: "隐私", en: "Privacy" }, "/privacy"],
    [{ zh: "安装", en: "Install" }, "#installation"],
    [{ zh: "下载", en: "Download" }, "/download"],
  ],
};
const screens = [
  {
    id: "overview",
    icon: Activity,
    zh: "实时额度",
    en: "Overview",
    src: "/assets/dashboard-hero.webp",
    enAlt:
      "Quota Monitor dashboard showing Codex and Claude Code quota cards, reset times and usage trends with demonstration data.",
    zhAlt: "额度概览，同屏查看 Codex 和 Claude Code 的额度与重置时间。",
  },
  {
    id: "trends",
    icon: History,
    zh: "使用趋势",
    en: "Trends",
    src: "/assets/dashboard-insights.webp",
    enAlt:
      "Dashboard insights including a yearly activity heatmap, provider totals and model composition.",
    zhAlt: "使用趋势，按日期查看活跃度、模型占比与使用构成。",
  },
  {
    id: "sessions",
    icon: ListTree,
    zh: "会话明细",
    en: "Sessions",
    src: "/assets/sessions-detail.webp",
    enAlt: "Sessions view with searchable model, token and timing details.",
    zhAlt: "会话明细，可对照模型、Token 与调用时间。",
  },
];
export function Hero({ lang }) {
  const [key, setKey] = useState("overview");
  const zh = lang === "zh";
  const t = copy[lang];
  const tabs = screens.map((screen) => ({
    ...screen,
    label: zh ? screen.zh : screen.en,
  }));
  return (
    <section className="pi-hero quota-desk" aria-labelledby="hero-title">
      <div className="pi-container quota-spread">
        <div className="quota-side">
          <img
            className="quota-icon"
            src="/assets/app-icon.png"
            alt=""
            width={66}
            height={66}
          />
          <h1 id="hero-title">Quota Monitor</h1>
          <p className="quota-purpose" data-i18n="heroDescription">
            {zh
              ? "在 Mac 上查看 Codex 和 Claude Code 的剩余额度、重置时间与使用记录。"
              : "Track your Codex and Claude Code quotas, reset times, and usage history on your Mac."}
          </p>
          <div className="quota-download">
            <Action href="/download" icon={Download}>
              <span data-i18n="downloadAction">{t.downloadAction}</span>
            </Action>
            <small data-i18n="freeNote">{t.freeNote}</small>
            <a href="#installation">{zh ? "安装说明" : "Installation guide"}</a>
          </div>
          <div className="quota-popover-example">
            <h2>{zh ? "菜单栏弹窗" : "Menu bar popover"}</h2>
            <p data-i18n="overviewDetail">{t.overviewDetail}</p>
            <Figure
              src="/assets/menu-bar-popover.webp"
              width={386}
              height={661}
              title={zh ? "菜单栏额度" : "Menu bar quotas"}
              altKey="menuPopoverAlt"
              alt={t.menuPopoverAlt}
              lang={lang}
            />
          </div>
        </div>
        <div className="quota-main">
          <div className="quota-view-heading">
            <h2>{zh ? "仪表盘" : "Dashboard"}</h2>
            <span>{zh ? "示例数据" : "Sample data"}</span>
          </div>
          <Choices
            keepPanels
            label={zh ? "浏览产品界面" : "Explore the app"}
            tabs={tabs}
            value={key}
            onChange={setKey}
          >
            {(screen, active) => {
              const altKey = {
                overview: "dashboardHeroAlt",
                trends: "dashboardTrendsAlt",
                sessions: "sessionsDetailAlt",
              }[screen.id];
              return (
                <Figure
                  src={screen.src}
                  width={980}
                  height={732}
                  altKey={altKey}
                  alt={t[altKey]}
                  title={screen.label}
                  lang={lang}
                  priority={active}
                />
              );
            }}
          </Choices>
          <p className="quota-view-caption" aria-live="polite">
            {zh
              ? {
                  overview:
                    "Codex 和 Claude Code 在同一张视图里分别显示额度与重置时间。",
                  trends: "按日期查看活跃度、模型用量和 Token 分布。",
                  sessions: "查看每个会话的模型、Token 数和调用时间。",
                }[key]
              : {
                  overview:
                    "Codex and Claude Code each show their own allowance and reset time.",
                  trends:
                    "Explore activity, model usage and token totals by date.",
                  sessions:
                    "Look up the model, token totals and timestamps for a session.",
                }[key]}
          </p>
        </div>
      </div>
    </section>
  );
}
