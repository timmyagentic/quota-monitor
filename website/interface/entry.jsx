import React from "react";
import { Header, FAQ, Notifications, useLanguage } from "./ui.jsx";
import { site, Hero } from "./Page.jsx";
import { ReadingIndex } from "./ReadingIndex.jsx";
import reading from "./reading.json";
import questions from "./questions.json";

export function Surface({ part }) {
  const lang = useLanguage(site.lang);
  if (part.startsWith("toc-"))
    return <ReadingIndex entries={reading[part.slice(4)]} lang={lang} />;
  if (part === "header") return <Header site={site} lang={lang} />;
  if (part === "faq") return <FAQ items={questions} lang={lang} />;
  return (
    <>
      <Hero lang={lang} />
      <Notifications lang={lang} />
    </>
  );
}
