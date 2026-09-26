import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import App from "./kelola-coffee-shop.jsx";

createRoot(document.getElementById("root")).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
