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

const SW_VERSION = 'phase3-2026-08-15';

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

/* ───────────────────────────────────────────────────────────────
 * Phase 3: push / notificationclick
 *
 * ★install / activate / fetch は無変更。ここから下は純粋な追加なので、
 *   キャッシュを持たない設計も kill switch（§14-9）もそのまま維持される。
 * ─────────────────────────────────────────────────────────────── */

const NOTIF_FALLBACK = {
  title: 'E-Li',
  body:  '新しいお知らせがあります',
  tag:   'eli-generic',
  url:   '/',
  kind:  'generic',
  id:    null,
};

function parsePushPayload(event) {
  // ★event.data が null でも無視しない。無視すると
  //   「送ったのに出ない」の切り分けができなくなる（§14-6 の教訓）。
  if (!event.data) return { ...NOTIF_FALLBACK };
  let raw;
  try {
    raw = event.data.json();
  } catch (e) {
    // JSON で来なかった場合もテキストとして拾わず汎用文言に倒す。
    // 本文に案件情報が混ざる事故を防ぐため、生テキストは表示しない。
    return { ...NOTIF_FALLBACK };
  }
  if (!raw || typeof raw !== 'object') return { ...NOTIF_FALLBACK };
  const kind = typeof raw.kind === 'string' ? raw.kind : NOTIF_FALLBACK.kind;
  const id   = (typeof raw.id === 'string' || typeof raw.id === 'number') ? String(raw.id) : null;
  return {
    // ★title / body は送信側が入れた汎用文言をそのまま使う。
    //   案件の具体情報（現場名・住所・顧客名）は載せない方針（8/1 メール通知と同じ。
    //   Push はロック画面に出るぶんメールより慎重に扱う）。
    title: typeof raw.title === 'string' && raw.title ? raw.title : NOTIF_FALLBACK.title,
    body:  typeof raw.body  === 'string' && raw.body  ? raw.body  : NOTIF_FALLBACK.body,
    // ★tag は <kind>-<id>。種別 × 案件で一意にして見逃しを防ぐ。
    //   同じ tag なら置き換わる（Web Push の仕様。§14-6 で踏んだ）。
    tag:   typeof raw.tag === 'string' && raw.tag ? raw.tag : (id ? `${kind}-${id}` : NOTIF_FALLBACK.tag),
    // ★kind も URL に載せる。タブが無い状態から openWindow された場合、
    //   index.html 側はこの ?kind= だけが種別を知る手がかりになる（postMessage 経路と対称）。
    //   ★Edge Function 側は url を送らないこと。送ると &kind= が付かず②経路が chat に倒れる。
    url:   typeof raw.url === 'string' && raw.url.startsWith('/')
             ? raw.url
             : (id ? `/?order=${encodeURIComponent(id)}&kind=${encodeURIComponent(kind)}` : '/'),
    kind,
    id,
  };
}

self.addEventListener('push', (event) => {
  const p = parsePushPayload(event);
  // ★waitUntil で包まないと、showNotification の解決前に SW が停止して
  //   通知が出ないことがある。
  event.waitUntil(
    self.registration.showNotification(p.title, {
      body: p.body,
      tag:  p.tag,
      // 同じ tag の通知が既にあっても、置き換え時に再度知らせる
      renotify: true,
      // ★badge は Android のステータスバーで単色シルエットに潰される。
      //   icon-192 は通常アイコンなので白い塊になりうる。
      //   Chrome デスクトップでは badge 自体が無視されるため今週末は影響なし。
      //   単色の badge-72.png は来週の実機確認とあわせて作る（TODO）。
      icon:  '/icon-192.png',
      badge: '/icon-192.png',
      data:  { url: p.url, kind: p.kind, id: p.id, tag: p.tag, v: SW_VERSION },
    })
  );
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const data = event.notification.data || {};
  const url  = typeof data.url === 'string' && data.url.startsWith('/') ? data.url : '/';

  event.waitUntil((async () => {
    const all = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });

    // ★既存タブがあれば focus して postMessage で案件IDを渡す。
    //   openWindow で開き直すと、ログイン済みの状態を捨てて再読み込みになる。
    //   まず同一オリジンのタブを探す。
    const origin = self.location.origin;
    const target = all.find((c) => {
      try { return new URL(c.url).origin === origin; } catch (e) { return false; }
    });

    if (target) {
      try { await target.focus(); } catch (e) { /* focus 不可でも postMessage は試す */ }
      target.postMessage({
        source: 'eli-sw',
        type:   'notification-click',
        kind:   data.kind || null,
        id:     data.id   || null,
        url,
      });
      return;
    }

    // ★タブが無ければ新規に開く。index.html 側で ?order= を拾う必要がある。
    if (self.clients.openWindow) {
      await self.clients.openWindow(url);
    }
  })());
});
