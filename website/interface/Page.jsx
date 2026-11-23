import React, { useState } from "react";
import {
  Activity,
  History,
  ListTree,
  PanelTop,
  Download,
  Monitor,
} from "lucide-react";
import { Action, Choices, Figure, HeroCopy, Mark, tx } from "./ui.jsx";
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
  const [key, setKey] = useState("overview"),
    zh = lang === "zh";
  const t = copy[lang];
  const tabs = screens.map((s) => ({ ...s, label: zh ? s.zh : s.en }));
  return (
    <section className="pi-hero quota-desk" aria-labelledby="hero-title">
      <div className="pi-container">
        <div className="quota-intro">
          <HeroCopy
            mark={<Mark Icon={Monitor}>macOS · Codex / Claude Code</Mark>}
            title={
              <>
                <span data-i18n="heroTitleFirstLine">
                  {t.heroTitleFirstLine}
                </span>
                <br />
                <span data-i18n="heroTitleSecondLine">
                  {t.heroTitleSecondLine}
                </span>
              </>
            }
            description={
              zh
                ? "查看当前额度、重置时间与使用趋势。历史数据保存在你的 Mac 上。"
                : "Codex and Claude Code quotas, reset times, and usage trends. Right in your Mac menu bar."
            }
          />
          <div className="quota-download">
            <Action href="/download" icon={Download}>
              <span data-i18n="downloadAction">{t.downloadAction}</span>
            </Action>
            <a href="#installation">
              {zh ? "查看安装步骤" : "Installation guide"}
            </a>
            <small data-i18n="freeNote">{t.freeNote}</small>
          </div>
        </div>
        <div className="quota-stage">
          <div className="quota-side">
            <PanelTop size={24} />
            <h2>{zh ? "菜单栏与仪表盘" : "Menu bar and dashboard"}</h2>
            <p data-i18n="overviewDetail">{t.overviewDetail}</p>
            <Figure
              src="/assets/menu-bar-popover.webp"
              width={386}
              height={661}
              title={zh ? "菜单栏额度" : "Menu bar quotas"}
              altKey="menuPopoverAlt"
              alt={t.menuPopoverAlt}
              lang={lang}
              priority
            />
          </div>
          <div className="quota-main">
            <Choices
              keepPanels
              label={zh ? "浏览产品界面" : "Explore the app"}
              tabs={tabs}
              value={key}
              onChange={setKey}
            >
              {(screen, active) => (
                <Figure
                  src={screen.src}
                  width={980}
                  height={732}
                  altKey={
                    {
                      overview: "dashboardHeroAlt",
                      trends: "dashboardTrendsAlt",
                      sessions: "sessionsDetailAlt",
                    }[screen.id]
                  }
                  alt={
                    t[
                      {
                        overview: "dashboardHeroAlt",
                        trends: "dashboardTrendsAlt",
                        sessions: "sessionsDetailAlt",
                      }[screen.id]
                    ]
                  }
                  title={screen.label}
                  lang={lang}
                  priority={active}
                />
              )}
            </Choices>
            <p className="quota-proof">
              {zh
                ? "真实应用界面 · 演示数据"
                : "Actual app interface · Demonstration data"}
            </p>
          </div>
        </div>
      </div>
    </section>
  );
}
