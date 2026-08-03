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

function json(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
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

    // ── 5. 送信可否のガード ──────────────────────────────
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
    // ★ user_id が無い案件には送らない。宛先を推測しない。
    if (!order.user_id)     return await skip('order has no user_id');
    // ★ 状態の再確認。トリガー発火後に変えられていたら送らない。
    if (order.status !== ev.expectedStatus) {
      return await skip(`status changed to ${order.status}`);
    }

    // ── 6. 通知除外フラグ ＋ 宛名（profiles を1回だけ引く） ──────
    //   通知ベル・未読集計と同じ除外規約に従う。
    //   name は宛名の差し込みにのみ使う。ログには残さない。
    const { data: prof, error: profErr } = await admin
      .from('profiles')
      .select('eli_notification_excluded, name')
      .eq('id', order.user_id)
      .maybeSingle();

    if (profErr) throw new Error(`profiles select: ${profErr.message}`);
    if (prof?.eli_notification_excluded) {
      return await skip('eli_notification_excluded');
    }

    const displayName = resolveName(prof?.name as string | null | undefined);

    // ── 7. 宛先の解決（auth.users は service_role でしか読めない） ──
    //   ★ 検索はしない。orders.user_id を主キー指定で引くだけ。
    //     これにより E-Li に発注のあるユーザー以外には原理的に届かない。
    const { data: userRes, error: userErr } =
      await admin.auth.admin.getUserById(order.user_id);

    if (userErr) throw new Error(`getUserById: ${userErr.message}`);

    const to = userRes?.user?.email;
    if (!to) return await skip('user has no email');

    const toDomain = to.slice(to.indexOf('@'));   // ログにはドメインのみ残す

    // ── 8. Resend で送信（html + text の2本立て） ───────────
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
      await writeLog(admin, {
        order_id: orderId, event: eventKey, result: 'error',
        detail: `resend ${resendRes.status}: ${errBody.slice(0, 200)}`,
        to_domain: toDomain,
      });
      // 500 を返してもトリガー側は何もしない（pg_net は再送しない）。
      // 記録のためにステータスだけ正直に返す。
      return json({ error: 'resend failed' }, 500);
    }

    await writeLog(admin, {
      order_id: orderId, event: eventKey, result: 'sent',
      detail: 'ok', to_domain: toDomain,
    });
    return json({ success: true }, 200);

  } catch (e) {
    console.error('Unexpected error:', e);
    await writeLog(admin, {
      order_id: orderId, event: eventKey || '(none)', result: 'error',
      detail: String(e).slice(0, 300), to_domain: null,
    });
    return json({ error: 'internal error' }, 500);
  }
});
