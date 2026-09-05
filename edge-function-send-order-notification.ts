// ================================================================
// Supabase Edge Function: send-order-notification
// ================================================================
// E-Li 工事受発注システム — 顧客向けイベント通知メール（A案：即時送信）
//
// 呼び出し元:
//   public.orders のトリガー（add_email_notification_*.sql）が
//   pg_net 経由で POST する。
//   ★ ブラウザからは呼ばない。index.html には一切手を入れない。
//
// デプロイ: Supabase ダッシュボード → Edge Functions → New Function
//   関数名 : send-order-notification
//   ★ Verify JWT を OFF にすること。
//     DBトリガーは JWT を持たないため。代わりに共有シークレット
//     （x-eli-notify-secret ヘッダ）で認証する。
//
// 必要な Secrets（Edge Functions → Manage secrets）:
//   RESEND_API_KEY     : 既存（send-reset-email と共用）
//   SERVICE_ROLE_KEY   : 既存（★ Supabase は SUPABASE_ 接頭辞のシークレット名を
//                        許可しないため、この名前。send-reset-email と同一）
//   FROM_EMAIL         : 既存（既定 noreply@markan.co.jp）
//   ELI_NOTIFY_SECRET  : `openssl rand -hex 32` で生成した64桁の16進文字列
//   APP_URL            : https://eli.markan.co.jp
//                        （メール文面で eli.markan.co.jp を明示するため、
//                          vercel.app ではなくこちらに揃える）
//   ── Web Push（Phase 3 で参照開始・2026-08-16）────────────────
//   ELI_VAPID_PUBLIC_KEY  : VAPID 公開鍵（P-256 / base64url・87文字）。
//                           ★index.html:6794 に直書きしてある値と同一のもの。
//                           食い違うと Push サービスが 403 を返し全端末で失敗する
//   ELI_VAPID_PRIVATE_KEY : VAPID 秘密鍵（43文字）。★紛失すると全端末の購読が
//                           無効になり、鍵の再生成と全員の購読やり直しになる
//   ELI_VAPID_SUBJECT     : 連絡先。★`mailto:` か `https:` で始まること。
//                           形式違反だと setVapidDetails() が例外を投げる
//                           （sendPush の catch が拾うのでメールは止まらないが、
//                             Push は push:'error' になり静かに飛ばなくなる）
//   ※3件とも 2026-08-11 に登録済み（§14-11）。Phase 3 が初めての参照者。
//
// ----------------------------------------------------------------
// 2026-08-03 第2段階：4イベント対応
// ----------------------------------------------------------------
//   order_received   : 発注受付   （AFTER INSERT 起点）
//   schedule_fixed   : 日程確定   （第1段階から。文面を新体裁に統一）
//   cancelled        : キャンセル
//   schedule_consult : 日程相談中 （当社都合で別日を相談）
//
//   送らないステータス: 調整中への遷移・完了。
//   顧客発ステータス（日程変更相談中・キャンセル相談中）は送らない。
//     顧客自身の操作なので通知不要。当社側は通知ベルで気づく。
//
//   この版で追加したもの:
//     1. 宛名「○○様」の差し込み（profiles.name）
//        ★ HTML エスケープ必須。name は顧客がマイページで自由に編集できる。
//     2. 平文テキスト版の併記（HTML 単独はキャリアメールで弾かれやすい。
//        docomo 未着の一因である可能性があるため到達率対策として入れる）
//     3. 件名の共通接頭辞・名乗り・末尾のリンク注記を全イベントで統一
//
// send-reset-email との差分（意図的に変えた点）:
//   1. CORS を付けない。POST 以外は 405。サーバ間専用のため。
//   2. 共有シークレットで認証する（send-reset-email は無認証）。
//   3. 宛先をリクエストボディで受け取らない。order_id だけを受け取り、
//      orders → auth.users とサーバ側で解決する。これが
//      「他システムのユーザーに混入させない」ための唯一の担保。
//   4. 本文に案件情報を一切載せない（計画書 §12）。
// ================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const RESEND_API_KEY     = Deno.env.get('RESEND_API_KEY')!;
const SUPABASE_URL       = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_SERVICE_KEY = Deno.env.get('SERVICE_ROLE_KEY')!;
const FROM_EMAIL         = Deno.env.get('FROM_EMAIL') ?? 'noreply@markan.co.jp';
const NOTIFY_SECRET      = Deno.env.get('ELI_NOTIFY_SECRET')!;
const APP_URL            = Deno.env.get('APP_URL') ?? 'https://eli.markan.co.jp';
const APP_NAME           = 'E-Li 工事受発注システム';

// ----------------------------------------------------------------
// Web Push（Phase 3・2026-08-16）
// ----------------------------------------------------------------
// ★ ?? '' にする。! だと未設定時の型だけ黙らせることになり、
//   欠落を実行時まで持ち越す。sendPush 冒頭で明示的に skipped にする。
const VAPID_PUBLIC  = Deno.env.get('ELI_VAPID_PUBLIC_KEY')  ?? '';
const VAPID_PRIVATE = Deno.env.get('ELI_VAPID_PRIVATE_KEY') ?? '';
const VAPID_SUBJECT = Deno.env.get('ELI_VAPID_SUBJECT')     ?? '';

// ★ 案件情報（現場名・住所・日付・顧客名）を一切含めない汎用文言のみ。
//   Push はロック画面に出るぶんメールより慎重に扱う（§14-6 / 8-1 メール方針）。
// ★文面は顧客向けに中立化してある（2026-08-19）。
//   宛先は5イベントとも「管理者全員＋その案件の発注者1名（＝顧客）」で、
//   顧客のロック画面にも同じ文字列が出る。
//   ・主語を出さない。「届きました」「案件があります」は受け手が管理者である
//     前提の言い回しで、自分で発注した顧客が読むと他人事に見える。
//     起きた事実だけを書けばどちらの立場でも成立する。
//   ・「案件」という社内語を使わない。Push は案件ごとに1通で
//     （tag が `${kind}-${id}`）、複数をまとめた通知ではないため単数で書く。
const PUSH_TEXT: Record<string, { title: string; body: string }> = {
  order_received:   { title: 'E-Li ご依頼受付', body: 'ご依頼を受け付けました' },
  schedule_fixed:   { title: 'E-Li 日程確定',   body: '日程が確定しました' },
  cancelled:        { title: 'E-Li キャンセル', body: 'キャンセルが確定しました' },
  schedule_consult: { title: 'E-Li 日程調整',   body: '日程の調整を開始しました' },
  // ★メンションPush（2026-08-19）。案件情報も本文も一切載せない。
  //   誰にメンションされたかも書かない（ロック画面に人名を出さないため）。
  //   title は「メンション」ではなく「メッセージ」。顧客に確実に通じる語にする。
  mention:          { title: 'E-Li メッセージ', body: 'あなた宛のメッセージがあります' },
  // ★4日前確認の一斉送信（2026-08-30・段階3b）。宛先は各案件の発注者本人だけ。
  //   案件情報も施工日も載せない。対象が複数案件でも Push は案件ごとに1通で
  //   （tag が `chat-${order_id}`）、本文は全案件で同じ文字列になる。
  //   ★mention と文面を分ける理由：あちらは「あなた宛」に届いた個別の連絡、
  //     こちらは当社発の一斉確認。同じ body にすると受け手が区別できない。
  upcoming:         { title: 'E-Li メッセージ', body: 'ご確認のメッセージがあります' },
  // ★見積アップロード通知（2026-09-05・STEP4）。宛先は当該案件の発注者本人だけ。
  //   金額も案件情報も載せない（既存6件と同じ規則）。
  //   ★upcoming / mention と body を分ける理由：あちらは連絡・確認、
  //     こちらは見積の到着。同じ body にすると受け手が区別できない。
  estimate:         { title: 'E-Li お見積り',   body: 'お見積りをお送りしました' },
};

// リンク注記に出すドメイン。APP_URL から導出する。
//   ハードコードすると APP_URL を変えたときに
//   「※ボタンは eli.markan.co.jp へのリンクです」と書きながら
//   別のドメインへ飛ぶ、という食い違いが起きる。
const APP_HOST = (() => {
  try { return new URL(APP_URL).host; } catch { return 'eli.markan.co.jp'; }
})();

// ----------------------------------------------------------------
// 全メール共通の体裁（2026-08-03 確定）
// ----------------------------------------------------------------
const SUBJECT_PREFIX = '【大阪マルカン E-Li】';
const GREETING       = 'いつもお世話になっております。';
const SIGNATURE      = '株式会社大阪マルカン E-Li（イーライ）総合窓口です。';
const BUTTON_LABEL   = 'E-Li を開いて確認する';
const LINK_NOTE      = `※ボタンは当社サイト ${APP_HOST} へのリンクです。`;
const FOOTER_1       = 'このメールは送信専用です。ご返信いただいてもお答えできません。';
const FOOTER_2       = 'お問い合わせは E-Li のチャットからお願いいたします。';

// ----------------------------------------------------------------
// イベント定義
// ----------------------------------------------------------------
// expectedStatus: 送信直前に orders.status を読み直して照合する。
//   トリガー発火後・関数実行前に状態が変えられた場合に送信を止めるため
//   （pg_net は非同期なので、この時間差は実在する）。
//
// ★ 本文には案件情報（現場名・住所・日付・担当者名）を一切入れない。
//   計画書 §12「メールは転送・誤送信・端末での閲覧が制御できないため、
//   案件情報や会話内容をメール本文に含めない」。
//   日程確定通知であっても「確定した日付」は書かない。リンク先で認証を
//   通してから見せる。宛名だけは例外（誰宛かが分からないと読まれないため）。
//
// ★ subject は接頭辞を含めない。送信時に SUBJECT_PREFIX を付ける。
// ----------------------------------------------------------------
const EVENTS: Record<string, {
  expectedStatus: string;
  subject: string;
  heading: string;
  emoji: string;
  lines: string[];
}> = {
  // 発注受付。AFTER INSERT 起点。
  //   ★ expectedStatus は orders.status の DB 既定値と一致させること。
  //     index.html:3366 の発注フォームは status を指定せず既定値に任せている。
  //     STEP 0（check_orders_status_default.sql 0-1）で '調整中'::text を確認済みなら
  //     このままでよい。異なっていたらここを合わせる。
  order_received: {
    expectedStatus: '調整中',
    subject: 'ご依頼を受け付けました',
    heading: 'ご依頼を受け付けました',
    emoji: '📝',
    lines: [
      'この度はご依頼をいただき、ありがとうございます。無事に受け付けいたしました。',
      '担当者より追ってご連絡いたしますので、今しばらくお待ちください。',
      '内容は下のボタンから E-Li にてご確認いただけます。',
    ],
  },

  schedule_fixed: {
    expectedStatus: '日程確定',
    subject: '作業日程が確定しました',
    heading: '作業日程が確定しました',
    emoji: '📅',
    lines: [
      'ご依頼の作業について、日程が確定いたしました。',
      '内容は下のボタンから E-Li にてご確認いただけます。',
    ],
  },

  cancelled: {
    expectedStatus: 'キャンセル',
    subject: 'キャンセルを承りました',
    heading: 'キャンセルを承りました',
    emoji: '🗒',
    lines: [
      'ご依頼の作業について、キャンセルを承りました。',
      'またのご依頼を心よりお待ちしております。',
      '内容は下のボタンから E-Li にてご確認いただけます。',
    ],
  },

  // 当社都合で別日を相談したいとき。
  //   顧客発の「日程変更相談中」とは別のステータスなので混同しないこと。
  //   日程相談中へ遷移させているのは AdminApp の2箇所だけ
  //   （index.html:7578 の相談ボタン / :7954 のステータスセレクト）。
  schedule_consult: {
    expectedStatus: '日程相談中',
    subject: '日程についてのご相談',
    heading: '日程についてのご相談',
    emoji: '💬',
    lines: [
      'ご希望の日程について、担当者よりご相談させていただきたい件がございます。',
      'お手数ですが、下のボタンから E-Li にてご確認のうえ、ご返信いただけますと幸いです。',
    ],
  },
};

// ----------------------------------------------------------------
// HTML エスケープ
// ----------------------------------------------------------------
// ★ 必須。profiles.name は顧客がマイページで自由に編集できる値であり、
//   そのまま HTML に差し込むとメール本文にマークアップを注入できる。
//   本文の定型文は静的なのでエスケープ不要だが、宛名だけは必ず通す。
//   平文テキスト版にはエスケープを適用しない（HTML ではないため）。
function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

// ----------------------------------------------------------------
// 宛名の解決
// ----------------------------------------------------------------
// profiles.name をそのまま使うが、「仮名らしい値」は お客様 に落とす。
//
//   index.html はログイン時、profiles.name が空ならメールアドレスの @ 前を
//   仮名として自動 upsert する（CLAUDE.md「発注フォーム改善」）。
//   そのため name が空でなくても「mikanq1031」のような値が入り得る。
//   これをそのまま出すと「mikanq1031様」という宛名になる。
//
//   2026-08-03 実測（check_orders_status_default.sql 0-5）:
//     E-Li 利用者 15名 / 空 0 / @含む 0 / 英数字のみ 0 / 日本語 15
//   → 現状この関数がフォールバックすることは無い。新規ユーザー向けの保険。
//
//   ★ 英数字のみを弾くため、実名をローマ字表記している顧客も お客様 になる。
//     現在の利用者は全員日本語表記のため許容する。
//     外国人顧客が増えたらこの判定を見直すこと。
function resolveName(raw: string | null | undefined): string {
  const n = (raw ?? '').trim();
  if (!n) return 'お客様';
  if (n.includes('@')) return 'お客様';                    // メールアドレスがそのまま入っている
  if (/^[A-Za-z0-9._%+\-\s]+$/.test(n)) return 'お客様';   // 英数字のみ＝@前の仮名の疑い
  return n;
}

// ----------------------------------------------------------------
// 定数時間比較（シークレット照合）
// ----------------------------------------------------------------
// 単純な === は先頭一致の長さで応答時間が変わるため使わない。
function safeEqual(a: string, b: string): boolean {
  const ea = new TextEncoder().encode(a);
  const eb = new TextEncoder().encode(b);
  if (ea.length !== eb.length) return false;
  let diff = 0;
  for (let i = 0; i < ea.length; i++) diff |= ea[i] ^ eb[i];
  return diff === 0;
}

// ----------------------------------------------------------------
// 本文の組み立て
// ----------------------------------------------------------------
function buildHtml(ev: typeof EVENTS[string], name: string): string {
  const safeName = escapeHtml(name);
  const body = [GREETING, SIGNATURE, ...ev.lines];

  return `
<div style="font-family: 'Hiragino Sans', 'Yu Gothic', sans-serif; max-width: 560px; margin: 0 auto; padding: 32px 24px; background: #f4f7ff; border-radius: 16px;">
  <div style="text-align: center; margin-bottom: 24px;">
    <div style="font-size: 32px;">${ev.emoji}</div>
    <h1 style="font-size: 20px; font-weight: 800; color: #0a1f5c; margin: 8px 0 4px;">${ev.heading}</h1>
    <p style="font-size: 14px; color: #8a9cc5; margin: 0;">${APP_NAME}</p>
  </div>
  <div style="background: #ffffff; border-radius: 12px; padding: 24px; margin-bottom: 24px;">
    <p style="font-size: 15px; font-weight: 700; color: #0a1f5c; margin: 0 0 16px;">${safeName} 様</p>
    ${body.map((l) =>
      `<p style="font-size: 15px; color: #0a1f5c; margin: 0 0 16px; line-height: 1.7;">${l}</p>`
    ).join('')}
    <div style="text-align: center; margin: 24px 0 16px;">
      <a href="${APP_URL}" style="display: inline-block; background: #2952c8; color: #ffffff; font-size: 16px; font-weight: 800; text-decoration: none; padding: 14px 32px; border-radius: 10px;">
        ${BUTTON_LABEL}
      </a>
    </div>
    <p style="font-size: 12px; color: #8a9cc5; text-align: center; margin: 0;">${LINK_NOTE}</p>
  </div>
  <p style="font-size: 13px; color: #8a9cc5; text-align: center; margin: 0;">
    ${FOOTER_1}<br />
    ${FOOTER_2}
  </p>
</div>
  `.trim();
}

// 平文テキスト版。
//   ★ HTML 単独のメールはキャリアメール（docomo 等）で弾かれやすい。
//     multipart（html + text）で送ることが到達率対策になる。
//   ★ ここではエスケープしない。HTML ではないため。
function buildText(ev: typeof EVENTS[string], name: string): string {
  return [
    `${name} 様`,
    '',
    GREETING,
    SIGNATURE,
    '',
    ...ev.lines,
    '',
    `▼ ${BUTTON_LABEL}`,
    APP_URL,
    '',
    `※上記リンクは当社サイト ${APP_HOST} です。`,
    '',
    '--',
    FOOTER_1,
    FOOTER_2,
  ].join('\n');
}

// ----------------------------------------------------------------
// 送信ログ（eli_email_log）
// ----------------------------------------------------------------
// ここが失敗しても本処理は止めない。ログのためにメールを止めない。
async function writeLog(
  admin: ReturnType<typeof createClient>,
  row: {
    order_id: string | null;
    event: string;
    result: 'sent' | 'skipped' | 'error';
    detail: string;
    to_domain: string | null;
  },
) {
  const { error } = await admin.from('eli_email_log').insert(row);
  if (error) console.error('[eli_email_log]', error.message);
}

// ----------------------------------------------------------------
// Push 送信（Phase 3）
// ----------------------------------------------------------------
// ★ この関数は絶対に throw しない。呼び出し元（メール送信の後ろ）に
//   例外を返した瞬間、writeLog と同じ「本処理を止めない」原則が破れる。
// ★ eli_email_log には書かない。1通知あたりのログ行が倍になるため。
//   結果は console と応答 JSON にだけ出す。
type PushOutcome = {
  result: 'sent' | 'skipped' | 'error';
  detail: string;
  sent: number;
  removed: number;
};

// ----------------------------------------------------------------
// 送信と後片付け（①案件通知と②メンションで共有）
// ----------------------------------------------------------------
//   ★404/410 の DELETE 条件をここ1箇所だけに置く。2箇所に複製すると、
//     将来条件を変えたときに片方だけ直して取り残す。
//   ★この関数は throw しうる。呼び出し元は必ず try で囲むこと
//     （ここで握りつぶすと送信失敗が sent=0 と区別できなくなる）。
async function deliverToSubs(
  admin: ReturnType<typeof createClient>,
  subs: Array<Record<string, unknown>>,
  // ★string を渡すと全端末に同じ payload（既存2経路。従来と同一の道を通る）。
  //   関数を渡すと端末ごとに組み立てる（③一斉送信・2026-08-30 追加）。
  //   ★③だけ宛先が複数案件にまたがる。sw.js は payload の id から
  //     /?order= と tag=`${kind}-${id}` を作るので、id を1つに固定すると
  //     全員が同じ案件に飛ぶ。
  //   ★案件ごとに deliverToSubs を呼び分けなかったのは、404/410 の DELETE を
  //     全体で1クエリのまま保つため（この関数に1箇所だけ置く原則を崩さない）。
  payload: string | ((sub: Record<string, unknown>) => string),
): Promise<PushOutcome> {
  // ── ★動的 import ────────────────────────────────────
  //   静的 import が失敗すると関数自体が起動できず、
  //   既存のメール送信まで道連れになる（§14-5）。
  const webpush = (await import('npm:web-push@3.6.7')).default;
  webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC, VAPID_PRIVATE);

  const results = await Promise.allSettled(
    subs.map((row) =>
      webpush.sendNotification(
        {
          endpoint: row.endpoint as string,
          // ★★DB 列は auth_key。web-push が要求するのは keys.auth。
          //   素通しにすると auth が undefined になり暗号化が落ちる。
          //   列名を auth にできない理由は add_eli_push_subscriptions.sql の
          //   COMMENT（auth 列があると RLS 内の auth.uid() の解決が壊れうる）。
          keys: { p256dh: row.p256dh as string, auth: row.auth_key as string },
        },
        typeof payload === 'function' ? payload(row) : payload,
      )
    )
  );

  // ── 404 / 410 はその場で DELETE ────────────────────────
  //   pg_cron の掃除ジョブは作らない（定期実行そのものが恒常負荷・§14-4）。
  //   ★ DELETE は endpoint をまとめて1クエリ。端末ごとに1本ずつ打たない。
  const dead: string[] = [];
  let sent = 0;

  results.forEach((r, i) => {
    if (r.status === 'fulfilled') { sent++; return; }
    const code = (r.reason as { statusCode?: number } | undefined)?.statusCode;
    if (code === 404 || code === 410) {
      dead.push(subs[i].endpoint as string);
    } else {
      // 一時エラー。endpoint は消さない。
      // ★ fail_count も書かない（通知×端末数の UPDATE を増やさない）。
      console.error('[push] send failed', code ?? '(no status)', String(r.reason).slice(0, 200));
    }
  });

  if (dead.length > 0) {
    const { error: delErr } = await admin
      .from('eli_push_subscriptions')
      .delete()
      .in('endpoint', dead);
    if (delErr) console.error('[push] delete failed:', delErr.message);
  }

  // ★ last_ok_at は書かない。成功のたびに UPDATE すると
  //   通知1件 × 端末数の書き込みが恒常的に発生し絶対原則に反する。
  return { result: 'sent', detail: 'ok', sent, removed: dead.length };
}

async function sendPush(
  admin: ReturnType<typeof createClient>,
  orderId: string,
  eventKey: string,
): Promise<PushOutcome> {
  const none = (result: PushOutcome['result'], detail: string): PushOutcome =>
    ({ result, detail, sent: 0, removed: 0 });

  try {
    if (!VAPID_PUBLIC || !VAPID_PRIVATE || !VAPID_SUBJECT) {
      return none('skipped', 'vapid secrets missing');
    }
    const text = PUSH_TEXT[eventKey];
    if (!text) return none('skipped', `no push text for ${eventKey}`);

    // ── 宛先の解決 ─────────────────────────────────────
    //   宛先の決定は DB 側の RPC に委ねる。対象の判定と除外の適用は
    //   RPC の責務で、ここでは判定しない（同じ規則を2箇所に持たない）。
    //   ★ 往復は1回。返るのは endpoint / p256dh / auth_key の3列だけで、
    //     ua / last_ok_at / fail_count は使わない（従来どおり）。
    const { data: subs, error: subsErr } = await admin
      .rpc('get_push_targets', { p_order_id: orderId });

    if (subsErr) return none('error', `subs select: ${subsErr.message}`);
    //   ★ 'no push targets' … 購読が0件という意味ではない。
    //     購読はあってもこの案件の宛先に該当しない場合もここに来る。
    if (!subs || subs.length === 0) return none('skipped', 'no push targets');

    // ── ★ペイロードは id と kind だけ。url は送らない ──────────
    //   url を送ると &kind= が付かず、②経路（openWindow）が chat に倒れて
    //   ①経路（postMessage）と非対称になる（2026-08-15 確定）。
    //   URL の組み立ては sw.js の parsePushPayload が行う。
    //   tag も送らない（sw.js が `${kind}-${id}` を導出する）。
    const payload = JSON.stringify({
      title: text.title,
      body:  text.body,
      kind:  'change',   // 4イベントとも案件詳細タブへ
      id:    orderId,
    });

    // 送信と後片付けは deliverToSubs に集約（メンションPush と共有）。
    return await deliverToSubs(admin, subs, payload);

  } catch (e) {
    console.error('[push] unexpected:', e);
    return none('error', String(e).slice(0, 200));
  }
}

function json(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

// ----------------------------------------------------------------
// メンションPush（2026-08-19）
// ----------------------------------------------------------------
//   トリガー trg_eli_notify_mention → eli_notify_mention() が
//   { event:'mention', message_id } を投げてくる。order_id は来ない。
//
//   ★メールは送らない。Push だけ。メンションでメールまで送ると通知過多になる。
//   ★宛先の判定はしない。DB の get_push_targets_message が持つ責務
//     （同じ規則を2箇所に持たない。get_push_targets と同じ方針）。
//   ★エラーでも 200 を返す。pg_net 側にエラーを積まないため
//     （既存の skip() と同じ考え方）。invalid payload だけ 400。
async function handleMention(
  admin: ReturnType<typeof createClient>,
  body: Record<string, unknown>,
): Promise<Response> {
  const raw = body?.message_id;
  const messageId =
    typeof raw === 'string' || typeof raw === 'number' ? Number(raw) : NaN;

  if (!Number.isInteger(messageId) || messageId <= 0) {
    await writeLog(admin, {
      order_id: null, event: 'mention',
      result: 'error', detail: 'invalid message_id', to_domain: null,
    });
    return json({ error: 'invalid payload' }, 400);
  }

  const done = async (
    result: 'sent' | 'skipped' | 'error',
    detail: string,
    orderId: string | null,
  ) => {
    await writeLog(admin, {
      order_id: orderId, event: 'mention', result, detail, to_domain: null,
    });
    return json({ [result]: detail }, 200);
  };

  try {
    if (!VAPID_PUBLIC || !VAPID_PRIVATE || !VAPID_SUBJECT) {
      return await done('skipped', 'vapid secrets missing', null);
    }

    const text = PUSH_TEXT['mention'];
    if (!text) return await done('skipped', 'no push text for mention', null);

    // ── 宛先の解決（往復1回）────────────────────────────
    //   ★order_id もこの RPC が返す。全行同じ値。
    //     返さない設計にすると messages を引き直して往復が2回になる。
    const { data: subs, error: subsErr } = await admin
      .rpc('get_push_targets_message', { p_message_id: messageId });

    if (subsErr) return await done('error', `subs select: ${subsErr.message}`, null);

    // ★0件は正常系。自分しかメンションしていない／宛先が誰も購読していない、
    //   のどちらでもここに来る。購読0件という意味ではない。
    if (!subs || subs.length === 0) {
      return await done('skipped', 'no push targets', null);
    }

    // ★sw.js は payload の id を ?order= に使う。
    //   ここに message_id を入れると案件が開かない。
    const orderId = (subs[0] as { order_id?: string }).order_id ?? null;
    if (!orderId) return await done('error', 'rpc returned no order_id', null);

    const payload = JSON.stringify({
      title: text.title,
      body:  text.body,
      kind:  'chat',   // メンションはチャットタブへ（案件通知の 'change' と分ける）
      id:    orderId,
    });

    const out = await deliverToSubs(
      admin, subs as Array<Record<string, unknown>>, payload,
    );
    return await done(
      out.result, `${out.detail} sent=${out.sent} removed=${out.removed}`, orderId,
    );

  } catch (e) {
    console.error('[mention] unexpected:', e);
    return await done('error', String(e).slice(0, 200), null);
  }
}

// ----------------------------------------------------------------
// 4日前確認の一斉送信 Push（2026-08-30・段階3b ステップ4）
// ----------------------------------------------------------------
//   送信RPC eli_send_upcoming が { event:'upcoming', order_ids:[...] } を
//   投げてくる。チャットへの本文投入は RPC 側で bulk INSERT 済みで、
//   ここは Push を配るだけ。
//
//   ★メールは送らない。この経路から Resend は呼ばない。
//   ★宛先は get_push_targets_customers だけで解決する。
//     既存の get_push_targets は「発注者 ∪ 社内 admin/manager/staff 全員」の
//     UNION で、一斉送信に流用すると社内全員のロック画面に出る
//     （2026-08-30 に実データで確認。既存版=6 に対し customers版=3）。
//     ★このファイルで get_push_targets を呼ぶのは sendPush の1箇所だけ。
//       ここに増やさないこと。
//   ★DBへの往復は RPC 1回 ＋ ログ1行 ＋（死端末があれば）DELETE 1回。
//     対象案件数 N に依存しない。案件ごとにループしない。
//   ★エラーでも 200 を返す（pg_net にエラーを積まない。既存経路と同じ）。
//     invalid payload だけ 400。
const UPCOMING_MAX = 200;   // ★1呼び出しの上限。対象日の件数が想定外に
                            //   膨らんだとき無制限に走らないための歯止め。

async function handleUpcoming(
  admin: ReturnType<typeof createClient>,
  body: Record<string, unknown>,
): Promise<Response> {
  // ★ログは1呼び出しにつき1行。案件ごとに書くと N 行になる。
  //   order_id は単数で特定できないので null（mention の失敗時と同じ扱い）。
  const done = async (result: 'sent' | 'skipped' | 'error', detail: string) => {
    await writeLog(admin, {
      order_id: null, event: 'upcoming', result, detail, to_domain: null,
    });
    return json({ [result]: detail }, 200);
  };

  const bad = async (detail: string) => {
    await writeLog(admin, {
      order_id: null, event: 'upcoming',
      result: 'error', detail, to_domain: null,
    });
    return json({ error: 'invalid payload' }, 400);
  };

  // ── 入力の検証 ────────────────────────────────────────
  const raw = body?.order_ids;
  if (!Array.isArray(raw)) return await bad('order_ids is not an array');

  // ★文字列だけ残して重複を畳む。RPC 側も DISTINCT するが、ここで畳むと
  //   unnest に渡る配列そのものが短くなる。
  const orderIds = [...new Set(
    raw.filter((v): v is string => typeof v === 'string' && v.length > 0),
  )];

  if (orderIds.length > UPCOMING_MAX) {
    return await bad(`too many order_ids: ${orderIds.length}`);
  }

  try {
    // ★0件は正常系。対象日に該当案件が無い日は普通にある。
    if (orderIds.length === 0) return await done('skipped', 'no order_ids');

    if (!VAPID_PUBLIC || !VAPID_PRIVATE || !VAPID_SUBJECT) {
      return await done('skipped', 'vapid secrets missing');
    }

    const text = PUSH_TEXT['upcoming'];
    if (!text) return await done('skipped', 'no push text for upcoming');

    // ── 宛先の解決（往復1回・案件数に依存しない）──────────────
    //   返るのは endpoint / p256dh / auth_key / order_id の4列。
    //   宛先の判定と除外（is_system / eli_notification_excluded）の適用は
    //   RPC の責務で、ここでは判定しない（同じ規則を2箇所に持たない）。
    const { data: subs, error: subsErr } = await admin
      .rpc('get_push_targets_customers', { p_order_ids: orderIds });

    if (subsErr) return await done('error', `subs select: ${subsErr.message}`);

    // ★0件は正常系。対象の発注者が誰も購読していない場合もここに来る。
    //   購読が0件という意味ではない。
    if (!subs || subs.length === 0) {
      return await done('skipped', `no push targets (orders=${orderIds.length})`);
    }

    // ★order_id を持たない行は落とす（RPC は必ず返すので多層防御）。
    //   id が無い payload は sw.js が '/' に倒すため、届いても案件が開かない。
    const targets = (subs as Array<Record<string, unknown>>)
      .filter((s) => typeof s.order_id === 'string' && s.order_id);
    if (targets.length === 0) return await done('error', 'rpc returned no order_id');

    // ── payload は端末ごとに組み立てる ────────────────────────
    //   ★その端末の order_id を id に差す。1つに固定すると全員が同じ案件へ飛ぶ。
    //   ★url も tag も送らない。url を送ると &kind= が付かず②経路（openWindow）が
    //     chat に倒れて①経路（postMessage）と非対称になる（2026-08-15 確定）。
    //     tag は sw.js が `${kind}-${id}` を導出する。
    const payloadOf = (sub: Record<string, unknown>) => JSON.stringify({
      title: text.title,
      body:  text.body,
      kind:  'chat',   // 本文はチャットに入っているのでチャットタブへ
      id:    sub.order_id as string,
    });

    const out = await deliverToSubs(admin, targets, payloadOf);
    return await done(
      out.result,
      `${out.detail} orders=${orderIds.length} sent=${out.sent} removed=${out.removed}`,
    );

  } catch (e) {
    console.error('[upcoming] unexpected:', e);
    return await done('error', String(e).slice(0, 200));
  }
}

// ----------------------------------------------------------------
// 見積アップロード通知 Push（2026-09-05・STEP4）
// ----------------------------------------------------------------
//   送信RPC（STEP5）が { event:'estimate', order_id:'B-2026-XXX' } を投げてくる。
//   status 遷移を伴わないため、既存メール経路（EVENTS 照合・status 再確認）には
//   載らない。mention / upcoming と同じ早期リターン型。
//
//   ★二重送信の防止はここではやらない。
//     STEP5 の送信RPC が eli_order_estimates.notified_at IS NULL の
//     条件付き UPDATE で claim する。Edge は受け取った案件に配るだけ。
//   ★メールは送らない。この経路から Resend は呼ばない。
//   ★宛先は get_push_targets_customers だけで解決する。
//     get_push_targets は「発注者 ∪ 社内 admin/manager/staff 全員」の UNION で、
//     使うと社内全員のロック画面に見積通知が出る。
//     ★このファイルで get_push_targets を呼ぶのは sendPush の1箇所だけ。
//       ここに増やさないこと。
//   ★upcoming と違い案件が1件に定まるので、ログに order_id を残せる。
//   ★DBへの往復は RPC 1回 ＋ ログ1行 ＋（死端末があれば）DELETE 1回。
//   ★エラーでも 200 を返す（pg_net にエラーを積まない。既存経路と同じ）。
//     invalid payload だけ 400。
async function handleEstimate(
  admin: ReturnType<typeof createClient>,
  body: Record<string, unknown>,
): Promise<Response> {
  const orderId = typeof body?.order_id === 'string' ? body.order_id : '';

  // ★result は 'sent'/'skipped'/'error' の3値だけ。
  //   eli_email_log.result の CHECK 制約に従う（event 列に制約は無い）。
  const done = async (result: 'sent' | 'skipped' | 'error', detail: string) => {
    await writeLog(admin, {
      order_id: orderId || null, event: 'estimate', result, detail, to_domain: null,
    });
    return json({ [result]: detail }, 200);
  };

  const bad = async (detail: string) => {
    await writeLog(admin, {
      order_id: orderId || null, event: 'estimate',
      result: 'error', detail, to_domain: null,
    });
    return json({ error: 'invalid payload' }, 400);
  };

  // ── 入力の検証 ────────────────────────────────────────
  if (!orderId) return await bad('order_id is not a non-empty string');

  try {
    if (!VAPID_PUBLIC || !VAPID_PRIVATE || !VAPID_SUBJECT) {
      return await done('skipped', 'vapid secrets missing');
    }

    const text = PUSH_TEXT['estimate'];
    if (!text) return await done('skipped', 'no push text for estimate');

    // ── 宛先の解決（往復1回）──────────────────────────────
    //   RPC の引数は text[]。1件でも配列で渡す（単一版の関数は作らない。
    //   同じ規則を2箇所に持たないため）。
    //   宛先の判定と除外（is_system / eli_notification_excluded / deleted_at）の
    //   適用は RPC の責務で、ここでは判定しない。
    const { data: subs, error: subsErr } = await admin
      .rpc('get_push_targets_customers', { p_order_ids: [orderId] });

    if (subsErr) return await done('error', `subs select: ${subsErr.message}`);

    // ★0件は正常系。発注者が未購読 / is_system / 通知除外 / 案件が論理削除、
    //   のいずれでもここに来る。購読が0件という意味ではない。
    if (!subs || subs.length === 0) return await done('skipped', 'no push targets');

    // ── ★payload は文字列1本。url も tag も送らない ──────────────
    //   全端末が同じ1案件なので端末ごとの組み立ては不要
    //   （deliverToSubs の関数形は、複数案件にまたがる upcoming 専用）。
    //   ★kind は 'change'（案件詳細タブへ）。
    //     index.html:11578 / :11605 の判定は `kind === 'change' ? 'change' : 'chat'` で、
    //     'estimate' など未知の値を入れるとエラーにならず静かに chat へ倒れる。
    //   ★url を送ると &kind= が付かず②経路（openWindow）が chat に倒れて
    //     ①経路（postMessage）と非対称になる（2026-08-15 確定）。
    //     tag は sw.js が `${kind}-${id}` を導出する。
    const payload = JSON.stringify({
      title: text.title,
      body:  text.body,
      kind:  'change',
      id:    orderId,
    });

    // 送信と後片付けは deliverToSubs に集約（string 引数の既存分岐をそのまま通る）。
    const out = await deliverToSubs(admin, subs as Array<Record<string, unknown>>, payload);
    return await done(
      out.result,
      `${out.detail} sent=${out.sent} removed=${out.removed}`,
    );

  } catch (e) {
    console.error('[estimate] unexpected:', e);
    return await done('error', String(e).slice(0, 200));
  }
}

Deno.serve(async (req) => {
  // ── 1. メソッド制限（CORS は付けない。サーバ間専用） ──────────
  if (req.method !== 'POST') {
    return json({ error: 'method not allowed' }, 405);
  }

  // ── 2. 共有シークレット認証 ──────────────────────────────
  const given = req.headers.get('x-eli-notify-secret') ?? '';
  if (!NOTIFY_SECRET || !safeEqual(given, NOTIFY_SECRET)) {
    console.warn('[auth] rejected');
    return json({ error: 'unauthorized' }, 401);
  }

  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // ── 2-b. ★メンションPush の最優先分岐（2026-08-19）───────────
  //   ここで返すので、以降の既存メール経路には一切入らない。
  //   既存経路は order_id 必須・EVENTS 照合・orders.status の再確認を通るが、
  //   メンションはそのどれにも該当しない（案件の状態変化ではないため）。
  //
  //   ★req.clone() を使う理由：body は一度しか読めない。
  //     既存の try 内にある `await req.json()` の行を書き換えずに済ませるため、
  //     ここでは複製から読む。既存経路のコードは1行も変えていない。
  const peek = await req.clone().json().catch(() => ({}));
  if (peek?.event === 'mention') {
    return await handleMention(admin, peek);
  }

  // ── 2-c. ★4日前確認の一斉送信（2026-08-30・段階3b ステップ4）──────
  //   送信RPC eli_send_upcoming が
  //   { event:'upcoming', order_ids:[...] } を pg_net で投げてくる。
  //   order_id（単数）は来ないので、mention と同じくここで返す。
  //   以降の既存メール経路（order_id 必須・EVENTS 照合・status 再確認）には
  //   一切入らない。既存経路のコードは1行も変えていない。
  if (peek?.event === 'upcoming') {
    return await handleUpcoming(admin, peek);
  }

  // ── 2-d. ★見積アップロード通知（2026-09-05・STEP4）─────────────
  //   送信RPC が { event:'estimate', order_id:'B-...' } を投げてくる。
  //   order_id は来るが EVENTS には無いイベントなので、ここで返す。
  //   ★この分岐は EVENTS 照合（下の `EVENTS[eventKey]`）より必ず手前に置くこと。
  //     後ろに置くと 'estimate' が invalid payload で 400 になり通知が飛ばない。
  //   ★status 遷移を伴わないため、既存経路の expectedStatus 判定には載らない。
  //   既存経路のコードは1行も変えていない。
  if (peek?.event === 'estimate') {
    return await handleEstimate(admin, peek);
  }

  let orderId: string | null = null;
  let eventKey = '';

  try {
    // ── 3. 入力の検証 ────────────────────────────────────
    const body = await req.json().catch(() => ({}));
    orderId  = typeof body?.order_id === 'string' ? body.order_id : null;
    eventKey = typeof body?.event === 'string' ? body.event : '';

    const ev = EVENTS[eventKey];
    if (!orderId || !ev) {
      await writeLog(admin, {
        order_id: orderId, event: eventKey || '(none)',
        result: 'error', detail: 'invalid payload', to_domain: null,
      });
      return json({ error: 'invalid payload' }, 400);
    }

    // ── 4. 案件を引く（宛先解決の起点は必ず orders） ──────────
    const { data: order, error: orderErr } = await admin
      .from('orders')
      .select('id, user_id, status, deleted_at')
      .eq('id', orderId)
      .maybeSingle();

    if (orderErr) throw new Error(`orders select: ${orderErr.message}`);

    // ── 5. 共通の前提ガード（メールも Push も止める） ────────────
    //   ここで止まる理由は「案件そのものが対象外」なので Push も送らない。
    //   どれも「送らない」が正常系なので 200 を返す。
    //   pg_net 側にエラーを積まないため。
    const skip = async (detail: string) => {
      await writeLog(admin, {
        order_id: orderId, event: eventKey,
        result: 'skipped', detail, to_domain: null,
      });
      return json({ skipped: detail }, 200);
    };

    if (!order)             return await skip('order not found');
    if (order.deleted_at)   return await skip('order deleted');
    // ★ 状態の再確認。トリガー発火後に変えられていたら送らない。
    if (order.status !== ev.expectedStatus) {
      return await skip(`status changed to ${order.status}`);
    }

    // ── 6〜8. メール送信（顧客宛） ────────────────────────────
    //   ★ ここから先の「送らない」は顧客側の事情であって、
    //     管理者宛の Push を止める理由にならない。
    //     よって handler を return せず、結果を変数に落として先へ流す。
    //   ★ 例外もここで受け止める。外の catch まで投げると Push が実行されない。
    const mail: {
      result: 'sent' | 'skipped' | 'error';
      detail: string;
      toDomain: string | null;
    } = await (async () => {
      try {
        // ★ user_id が無い案件には送らない。宛先を推測しない。
        if (!order.user_id) {
          return { result: 'skipped' as const, detail: 'order has no user_id', toDomain: null };
        }

        // 通知除外フラグ ＋ 宛名（profiles を1回だけ引く）
        //   通知ベル・未読集計と同じ除外規約に従う。
        //   name は宛名の差し込みにのみ使う。ログには残さない。
        const { data: prof, error: profErr } = await admin
          .from('profiles')
          .select('eli_notification_excluded, name')
          .eq('id', order.user_id)
          .maybeSingle();

        if (profErr) throw new Error(`profiles select: ${profErr.message}`);
        if (prof?.eli_notification_excluded) {
          return { result: 'skipped' as const, detail: 'eli_notification_excluded', toDomain: null };
        }

        const displayName = resolveName(prof?.name as string | null | undefined);

        // 宛先の解決（auth.users は service_role でしか読めない）
        //   ★ 検索はしない。orders.user_id を主キー指定で引くだけ。
        //     これにより E-Li に発注のあるユーザー以外には原理的に届かない。
        const { data: userRes, error: userErr } =
          await admin.auth.admin.getUserById(order.user_id);

        if (userErr) throw new Error(`getUserById: ${userErr.message}`);

        const to = userRes?.user?.email;
        if (!to) {
          return { result: 'skipped' as const, detail: 'user has no email', toDomain: null };
        }

        const toDomain = to.slice(to.indexOf('@'));   // ログにはドメインのみ残す

        // Resend で送信（html + text の2本立て）
        const resendRes = await fetch('https://api.resend.com/emails', {
          method: 'POST',
          headers: {
            'Authorization': `Bearer ${RESEND_API_KEY}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({
            from: `${APP_NAME} <${FROM_EMAIL}>`,
            to: [to],
            subject: `${SUBJECT_PREFIX}${ev.subject}`,
            html: buildHtml(ev, displayName),
            text: buildText(ev, displayName),
          }),
        });

        if (!resendRes.ok) {
          const errBody = await resendRes.text();
          console.error('Resend error:', resendRes.status, errBody);
          return {
            result: 'error' as const,
            detail: `resend ${resendRes.status}: ${errBody.slice(0, 200)}`,
            toDomain,
          };
        }

        return { result: 'sent' as const, detail: 'ok', toDomain };

      } catch (e) {
        console.error('[mail] error:', e);
        return { result: 'error' as const, detail: String(e).slice(0, 300), toDomain: null };
      }
    })();

    // ── 9. Push 送信（管理者全員＋発注者1名）★必ずメールの後ろ ──────
    //   前に置くと web-push の動的 import や Push サービスへの往復で
    //   メール送信が遅れる。sendPush は throw しない契約。
    const push = await sendPush(admin, orderId, eventKey);

    // ── 10. ログ1行 ＋ 単一 return ──────────────────────────
    //   eli_email_log の行数はこれまでどおり1呼び出しにつき1行。
    await writeLog(admin, {
      order_id: orderId, event: eventKey,
      result: mail.result, detail: mail.detail, to_domain: mail.toDomain,
    });

    console.log('[push]', push.result, push.detail, 'sent=', push.sent, 'removed=', push.removed);

    // 500 を返してもトリガー側は何もしない（pg_net は再送しない）。
    // 記録のためにステータスだけ正直に返す。
    return json(
      {
        mail: mail.result,
        mail_detail: mail.detail,
        push: push.result,
        push_sent: push.sent,
        push_removed: push.removed,
      },
      mail.result === 'error' ? 500 : 200,
    );

  } catch (e) {
    console.error('Unexpected error:', e);
    await writeLog(admin, {
      order_id: orderId, event: eventKey || '(none)', result: 'error',
      detail: String(e).slice(0, 300), to_domain: null,
    });
    return json({ error: 'internal error' }, 500);
  }
});
