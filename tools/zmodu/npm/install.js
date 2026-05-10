// @ts-check
"use strict";

const os = require("os");
const fs = require("fs");
const path = require("path");
const https = require("https");

const PLATFORM_MAP = /** @type {const} */ ({
  darwin: "macos",
  linux: "linux",
});

const ARCH_MAP = /** @type {const} */ ({
  x64: "x86_64",
  arm64: "aarch64",
});

function getVersion() {
  try {
    return require("./package.json").version;
  } catch (_) {
    return "0.6.0";
  }
}

function getRepo() {
  try {
    const pkg = require("./package.json");
    const url = new URL(pkg.repository.url);
    return url.pathname.replace(/\.git$/, "").replace(/^\//, "");
  } catch (_) {
    return "knot3bot/zigmodu";
  }
}

function getPackageName() {
  try {
    const pkg = require("./package.json");
    return pkg.name;  // e.g. "@knot3bot/zmodu" or "zmodu"
  } catch (_) {
    return "zmodu";
  }
}

function getPlatform() {
  const plat = os.platform();
  const mapped = PLATFORM_MAP[plat];
  if (!mapped) {
    console.error(
      `zmodu: unsupported platform "${plat}". Supported: darwin, linux.`
    );
    process.exit(1);
  }
  return mapped;
}

function getArch() {
  const arch = os.arch();
  const mapped = ARCH_MAP[arch];
  if (!mapped) {
    console.error(
      `zmodu: unsupported architecture "${arch}". Supported: x64, arm64.`
    );
    process.exit(1);
  }
  return mapped;
}

/**
 * @param {string} url
 * @param {string} dest
 * @returns {Promise<void>}
 */
function download(url, dest) {
  return new Promise((resolve, reject) => {
    const file = fs.createWriteStream(dest);

    function follow(location) {
      https
        .get(location, (response) => {
          if (
            response.statusCode &&
            response.statusCode >= 300 &&
            response.statusCode < 400 &&
            response.headers.location
          ) {
            follow(response.headers.location);
            return;
          }
          if (response.statusCode && response.statusCode >= 400) {
            reject(
              new Error(
                `Download failed: HTTP ${response.statusCode} from ${location}`
              )
            );
            return;
          }
          response.pipe(file);
          file.on("finish", () => {
            file.close();
            resolve();
          });
        })
        .on("error", reject);
    }

    follow(url);
  });
}

async function main() {
  const version = getVersion();
  const repo = getRepo();
  const platform = getPlatform();
  const arch = getArch();

  const tag = `zmodu-v${version}`;
  const baseUrl = `https://github.com/${repo}/releases/download/${tag}`;
  const archiveName = `zmodu-${platform}-${arch}.tar.gz`;
  const url = `${baseUrl}/${archiveName}`;

  // Destination in the npm package's bin directory
  const binDir = path.join(__dirname, "bin");
  const destBinary = path.join(binDir, "zmodu-bin");

  // Also cache to ~/.zmodu/ for version persistence
  const dataDir = path.join(os.homedir(), ".zmodu");
  const cachedBinary = path.join(dataDir, `zmodu-${version}`);

  // Check if already installed
  if (fs.existsSync(destBinary)) {
    console.log(`zmodu: binary already installed.`);
    return;
  }

  console.log(`zmodu v${version}: downloading ${platform}-${arch} binary ...`);

  try {
    fs.mkdirSync(binDir, { recursive: true });
    fs.mkdirSync(dataDir, { recursive: true });

    const tmpArchive = path.join(os.tmpdir(), `zmodu-${version}-${platform}-${arch}.tar.gz`);
    await download(url, tmpArchive);

    // Extract
    const { execSync } = require("child_process");
    const tar = process.platform === "darwin" ? "/usr/bin/tar" : "tar";
    execSync(`${tar} -xzf "${tmpArchive}" -C "${binDir}"`, { stdio: "pipe" });

    // Rename extracted binary and cache it
    const extracted = path.join(binDir, "zmodu");
    if (fs.existsSync(extracted)) {
      // Cache to ~/.zmodu/
      fs.copyFileSync(extracted, cachedBinary);
      // Rename to zmodu-bin so the shell wrapper finds it
      fs.renameSync(extracted, destBinary);
    }

    // Clean up
    try { fs.unlinkSync(tmpArchive); } catch (_) {}

    // Make executable
    try { fs.chmodSync(destBinary, 0o755); } catch (_) {}
    try { fs.chmodSync(cachedBinary, 0o755); } catch (_) {}

    console.log(`zmodu v${version} installed successfully!`);
    console.log("  Run: zmodu --help");
  } catch (err) {
    console.error("zmodu: download failed:", err.message);
    console.error(
      `zmodu: install from source: https://github.com/${repo}`
    );
    process.exit(1);
  }
}

main();
