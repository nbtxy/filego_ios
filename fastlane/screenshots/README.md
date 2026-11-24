# App Store screenshots

Six 1320 × 2868 promotional frames (the App Store Connect 6.9-inch slot) for
`en-US`, `zh-Hans`, and `zh-Hant`. The app has no Traditional Chinese
localization, so `zh-Hant` deliberately reuses the English set.

The iPhone Duo set lives in `fastlane/screenshots-duo/` at **2853 × 2007**
(inner display, landscape/book pose). It uses the same six headlines and is
uploaded as the `APP_IPHONE_DUO` display type. Duo captures hide the status bar,
which otherwise sits on the right edge in this pose.

Each frame is a raw simulator capture wrapped in the same paper / ink / lime
marketing frame: a Stolnk wordmark, a two-line headline, and the app screen in a
rounded card. The first three frames carry the current pitch: AI work products
(HTML and Markdown) can be sent to the phone and read there rendered, not as
source.

| # | zh-Hans | en-US / zh-Hant |
|---|---|---|
| 1 | 把 AI 的成果装进口袋 — Drive root with an `AI 产物` folder | Put AI output in your pocket |
| 2 | HTML 打开就能看 — rendered HTML report | HTML, rendered not downloaded |
| 3 | Markdown 也排版好 — typeset Markdown with table and code | Markdown that looks finished |
| 4 | 电脑发，手机收 — receive address detail | Send from a browser. Read on your phone. |
| 5 | 扫个码，文件就过来 — address QR code | One scan, file delivered |
| 6 | US$9.99 终身买断 — paywall with yearly and lifetime options | US$9.99. Yours forever. |

## Regenerating

Raw captures live in `build/shots/` (git-ignored). To take them, build the app
into the `Shot iPhone 17 Pro Max` simulator, seed the sample files, and launch
with the debug-only screenshot arguments:

```bash
xcrun simctl launch booted com.nbtxy.filego \
  -screenshot-register maya -screenshot html      # or markdown / plan / inbox / qr
```

For a realistic address (`https://maya.stolnk.com` rather than
`localhost:5173`), run the production-origin preview locally:

```bash
npm run build && npx vite preview --port 5173 --strictPort
```

Then compose the frames with Pillow from the harness runtime:

```bash
/Users/laienguang/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/bin/python3 \
  Scripts/make-promo-screenshots.py --raw build/shots --out build/promo

# iPhone Duo, unfolded and held in the landscape book pose (2853 × 2007)
hinge -d <DUO_UDID> orient portrait
hinge -d <DUO_UDID> open
# capture with -screenshot-hide-status-bar, then:
/Users/laienguang/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/bin/python3 \
  Scripts/make-promo-screenshots.py --raw build/shots --out build/promo-duo-landscape --device duo-landscape
```

Copy `build/promo/zh-Hans` and `build/promo/en-US` over the matching folders
here, and copy `en-US` over `zh-Hant`. Copy `build/promo-duo/...` into
`fastlane/screenshots-duo/` the same way. The copy for all six frames lives in
`Scripts/make-promo-screenshots.py`, so the screenshots and the store text stay
in sync.

Upload the sets directly (fastlane 2.237 predates the Duo display type):

```bash
node Scripts/upload-screenshots.mjs --display-type APP_IPHONE_67 \
  --root fastlane/screenshots --replace
node Scripts/upload-screenshots.mjs --display-type APP_IPHONE_DUO \
  --root fastlane/screenshots-duo --replace
```

The pre-1.0 (JustFling) set is kept in
`fastlane/rejected_screenshots/legacy-1.0/`.
