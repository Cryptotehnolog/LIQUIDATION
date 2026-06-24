import { test, expect } from "@playwright/test";
import path from "node:path";

const dashboardUrl = process.env.DASHBOARD_URL ?? "http://127.0.0.1:18080";
const screenshotDir = process.env.DASHBOARD_SCREENSHOT_DIR ?? ".cache/dashboard-smoke";

test("collector dashboard handles null, empty, and stale source states", async ({ page }) => {
  const consoleErrors = [];
  page.on("console", (message) => {
    if (message.type() === "error") {
      consoleErrors.push(message.text());
    }
  });

  await page.goto(dashboardUrl, { waitUntil: "domcontentloaded" });

  await expect(page.getByRole("heading", { name: "Collector dashboard" })).toBeVisible();
  await expect(page.getByTestId("source-card-bybit-BTCUSDT")).toContainText("LIVE");
  await expect(page.getByTestId("source-card-bybit-BTCUSDT")).toContainText("strategy_primary");
  await expect(page.getByTestId("source-card-binance-btcusdt")).toContainText("NO PAYLOAD");
  await expect(page.getByTestId("source-card-binance-btcusdt")).toContainText("No payload yet");
  await expect(page.getByTestId("source-card-binance-btcusdt")).toContainText("diagnostic_only");
  await expect(page.getByTestId("source-card-bybit-ETHUSDT")).toContainText("STALE");
  await expect(page.getByTestId("latency-buckets")).toContainText(">=1000 ms");
  await expect(page.getByTestId("source-coverage")).toContainText("diagnostic");
  await expect(page.getByTestId("trend-summary")).toContainText("samples");
  await expect(page.getByTestId("storage-signal")).toContainText("73.7 KB");
  await expect(page.getByTestId("latest-replay")).toContainText("Latest Replay Artifact");
  await expect(page.getByTestId("latest-replay")).toContainText("btc-5m-fixture");
  await expect(page.getByTestId("latest-replay")).toContainText("signals");
  await expect(page.getByTestId("latest-replay")).toContainText("-0.1090");
  await expect(page.getByTestId("latest-replay")).toContainText("below threshold");
  await expect(page.getByTestId("latest-replay")).toContainText("STALE METADATA");
  await page.screenshot({ path: path.join(screenshotDir, "desktop.png"), fullPage: true });

  await page.setViewportSize({ width: 390, height: 844 });
  await expect(page.getByTestId("source-grid")).toBeVisible();
  await expect(page.getByTestId("source-card-binance-btcusdt")).toBeVisible();
  await page.screenshot({ path: path.join(screenshotDir, "mobile.png"), fullPage: true });
  await expect
    .poll(() => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth))
    .toBe(true);
  expect(consoleErrors).toEqual([]);
});
