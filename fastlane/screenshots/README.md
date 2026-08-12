# App Store screenshots

Export iPhone screenshots at **1242 × 2688**, one of the dimensions accepted by the
App Store Connect 6.5-inch slot. Save each localized set in `en-US/`, `zh-Hans/`,
and `zh-Hant/` with numeric filenames (`01.png` … `05.png`). The app currently
falls back to English on Traditional Chinese systems, so `zh-Hant` deliberately
reuses the English screenshots.

| # | Screen | en-US | zh-Hans | zh-Hant |
|---|---|---|---|---|
| 1 | Import-address dialog with the link visible | Send them a link. Get their files. | 发条链接，文件自己就来了 | English fallback |
| 2 | Expanded add menu | Add from anywhere. | 拍照、相册、文件，都能进来 | English fallback |
| 3 | File list | Everything in one place. | 文件都在一个地方 | English fallback |
| 4 | Account and storage drawer | Space and account at a glance. | 空间和账号，一眼看清 | English fallback |
| 5 | Pro paywall | 50 GB, flexible links, 5 GB direct uploads. | 50 GB、灵活有效期、单文件 5 GB 直传 | English fallback |

For screenshot 5, select `filego/Resources/FileGo.storekit` under Scheme → Run → Options → StoreKit Configuration before launching the app.
