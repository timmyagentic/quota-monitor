import React from "react";
import { Accordion } from "@heroui/react/accordion";
import { List, ChevronDown } from "lucide-react";
import { tx } from "./ui.jsx";
export function ReadingIndex({ entries, lang }) {
  return (
    <nav
      className="pi-reading-index"
      aria-label={lang === "en" ? "On this page" : "本页目录"}
    >
      <Accordion>
        <Accordion.Item id="contents">
          <Accordion.Heading level={3}>
            <Accordion.Trigger>
              <List size={17} />
              {lang === "en" ? "On this page" : "本页目录"}
              <ChevronDown size={16} />
            </Accordion.Trigger>
          </Accordion.Heading>
          <Accordion.Panel>
            <Accordion.Body>
              <ul>
                {entries.map((s) => (
                  <li key={s.id}>
                    <a href={"#" + s.id}>{tx(s.label, lang)}</a>
                  </li>
                ))}
              </ul>
            </Accordion.Body>
          </Accordion.Panel>
        </Accordion.Item>
      </Accordion>
    </nav>
  );
}
