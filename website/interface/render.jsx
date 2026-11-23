import React from "react";
import { renderToString } from "react-dom/server";
import { Surface } from "./entry.jsx";
export function render(part) {
  return renderToString(<Surface part={part} />, {
    identifierPrefix: "product-" + part + "-",
  });
}
