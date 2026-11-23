import React from "react";
import { hydrateRoot } from "react-dom/client";
import { Surface } from "./entry.jsx";
for (const element of document.querySelectorAll("[data-product-surface]")) {
  const part = element.dataset.productSurface;
  hydrateRoot(element, <Surface part={part} />, {
    identifierPrefix: "product-" + part + "-",
  });
}
