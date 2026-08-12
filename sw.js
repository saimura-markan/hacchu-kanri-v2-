/* E-Li Service Worker — Phase 1（PWA化）
 *
 * ★このSWはキャッシュを一切持たない。
 *   アプリ全体が index.html 1枚（574KB / 11,081行）なので、precache すると
 *   本番へデプロイしても古いアプリが出続ける。単一ファイル構成では
 *   precache が最大の事故要因（docs/notification-bell-plan.md §14-3）。
 *
 * ★fetch は素通り。respondWith を呼ばないため Supabase への通信は一切傍受しない。
 *
 * ★kill switch: このファイルの中身を §14-9 の撤去版に全置換して deploy すれば
 *   全端末から SW を撤去できる。/sw.js は no-cache 配信なので必ず届く。
 *
 * Phase 2/3 で push / notificationclick ハンドラをここに追加する。
 */

const SW_VERSION = 'phase1-2026-08-12';

self.addEventListener('install', () => {
  // precache しない。即座に次バージョンへ入れ替われるようにする
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    // 検証用SWが残したものも含め、全キャッシュを削除する
    const keys = await caches.keys();
    await Promise.all(keys.map((key) => caches.delete(key)));
    await self.clients.claim();
  })());
});

// 意図的に空。respondWith を呼ばないので全リクエストは素通りする。
// （インストール可能判定が fetch ハンドラの存在を要求する場合への保険）
self.addEventListener('fetch', () => {});
