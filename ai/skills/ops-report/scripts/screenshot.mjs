#!/usr/bin/env node

// Captures Grafana dashboard screenshots using Playwright with Bearer token auth.
// Designed to work with kubectl port-forwarded Grafana, bypassing Cognito entirely.

import { chromium } from "playwright";

const args = process.argv.slice(2);

function usage() {
  console.error(
    "Usage: screenshot.mjs --token <token> --port <port> --dashboards <uid1,uid2,...> --output <dir> [--from <time>] [--to <time>] [--width <px>] [--height <px>]"
  );
  process.exit(1);
}

function parseArgs(args) {
  const opts = {
    token: null,
    port: 13000,
    dashboards: [],
    output: "/tmp/grafana-screenshots",
    from: "now-24h",
    to: "now",
    width: 1400,
    height: 900,
  };

  for (let i = 0; i < args.length; i++) {
    switch (args[i]) {
      case "--token":
        opts.token = args[++i];
        break;
      case "--port":
        opts.port = parseInt(args[++i], 10);
        break;
      case "--dashboards":
        opts.dashboards = args[++i].split(",");
        break;
      case "--output":
        opts.output = args[++i];
        break;
      case "--from":
        opts.from = args[++i];
        break;
      case "--to":
        opts.to = args[++i];
        break;
      case "--width":
        opts.width = parseInt(args[++i], 10);
        break;
      case "--height":
        opts.height = parseInt(args[++i], 10);
        break;
      default:
        console.error(`Unknown argument: ${args[i]}`);
        usage();
    }
  }

  if (!opts.token || opts.dashboards.length === 0) {
    usage();
  }

  return opts;
}

async function captureScreenshots(opts) {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    viewport: { width: opts.width, height: opts.height },
    extraHTTPHeaders: {
      Authorization: `Bearer ${opts.token}`,
    },
  });

  const results = [];

  for (const uid of opts.dashboards) {
    const url = `http://localhost:${opts.port}/d/${uid}?from=${encodeURIComponent(opts.from)}&to=${encodeURIComponent(opts.to)}&kiosk=1`;
    const outputPath = `${opts.output}/${uid}.png`;

    const page = await context.newPage();
    try {
      console.error(`Capturing ${uid}...`);
      await page.goto(url, { waitUntil: "networkidle", timeout: 30000 });

      // Grafana panels animate after data loads; give them time to finish rendering.
      await page.waitForTimeout(2000);

      await page.screenshot({ path: outputPath, fullPage: false });
      results.push({ uid, path: outputPath });
      console.error(`  Saved ${outputPath}`);
    } catch (err) {
      console.error(`  Failed to capture ${uid}: ${err.message}`);
      results.push({ uid, path: null, error: err.message });
    } finally {
      await page.close();
    }
  }

  await context.close();
  await browser.close();

  return results;
}

const opts = parseArgs(args);
const results = await captureScreenshots(opts);

// Output JSON result to stdout (stderr is used for progress messages).
console.log(JSON.stringify(results, null, 2));
