// ================================================================
// Supabase Edge Function: send-reset-email
// ================================================================
// デプロイ先: Supabase ダッシュボード → Edge Functions → New Function
// 関数名: send-reset-email
// ================================================================
//
// 必要な Secrets（Edge Functions → Manage secrets）:
//   RESEND_API_KEY   : re_xxxxxxxxxx（Resendダッシュボードで取得）
//   SUPABASE_SERVICE_ROLE_KEY : サービスロールキー（ダッシュボード → Settings → API）
//
// Resend送信元メール: noreply@markan.co.jp
// ================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const RESEND_API_KEY         = Deno.env.get('RESEND_API_KEY')!;
const SUPABASE_URL           = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_SERVICE_KEY   = Deno.env.get('SERVICE_ROLE_KEY')!;
const FROM_EMAIL             = Deno.env.get('FROM_EMAIL') ?? 'noreply@markan.co.jp';
const APP_NAME               = 'E-Li 工事受発注システム';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const { email } = await req.json();
    if (!email) {
      return new Response(JSON.stringify({ error: 'email は必須です' }), {
        status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // サービスロールで管理者クライアントを作成
    const supabaseAdmin = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    // パスワードリセット用マジックリンクを生成
    const { data, error: linkError } = await supabaseAdmin.auth.admin.generateLink({
      type: 'recovery',
      email,
      options: {
        redirectTo: 'https://hacchu-kanri-v2.vercel.app',
      },
    });

    if (linkError || !data?.properties?.action_link) {
      console.error('generateLink error:', linkError);
      return new Response(JSON.stringify({ error: 'リンク生成に失敗しました' }), {
        status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const resetLink = data.properties.action_link;

    // Resend API でメール送信
    const resendRes = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${RESEND_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        from: `${APP_NAME} <${FROM_EMAIL}>`,
        to: [email],
        subject: '【E-Li】パスワードリセットのご案内',
        html: `
<div style="font-family: 'Hiragino Sans', 'Yu Gothic', sans-serif; max-width: 560px; margin: 0 auto; padding: 32px 24px; background: #f4f7ff; border-radius: 16px;">
  <div style="text-align: center; margin-bottom: 24px;">
    <div style="font-size: 32px;">🔑</div>
    <h1 style="font-size: 20px; font-weight: 800; color: #0a1f5c; margin: 8px 0 4px;">パスワードリセットのご案内</h1>
    <p style="font-size: 14px; color: #8a9cc5; margin: 0;">E-Li 工事受発注システム</p>
  </div>
  <div style="background: #ffffff; border-radius: 12px; padding: 24px; margin-bottom: 24px;">
    <p style="font-size: 15px; color: #0a1f5c; margin: 0 0 16px;">パスワードリセットのリクエストを受け付けました。</p>
    <p style="font-size: 15px; color: #0a1f5c; margin: 0 0 24px;">下のボタンをクリックして、新しいパスワードを設定してください。</p>
    <div style="text-align: center;">
      <a href="${resetLink}" style="display: inline-block; background: #2952c8; color: #ffffff; font-size: 16px; font-weight: 800; text-decoration: none; padding: 14px 32px; border-radius: 10px;">
        パスワードをリセットする
      </a>
    </div>
    <p style="font-size: 12px; color: #8a9cc5; margin: 20px 0 0; text-align: center;">このリンクは1時間で無効になります</p>
  </div>
  <p style="font-size: 13px; color: #8a9cc5; text-align: center; margin: 0;">
    このメールに心当たりがない場合は、無視していただいて問題ありません。
  </p>
</div>
        `,
      }),
    });

    if (!resendRes.ok) {
      const resendErr = await resendRes.json();
      console.error('Resend error:', resendErr);
      return new Response(JSON.stringify({ error: 'メール送信に失敗しました' }), {
        status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    return new Response(JSON.stringify({ success: true }), {
      status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });

  } catch (e) {
    console.error('Unexpected error:', e);
    return new Response(JSON.stringify({ error: 'サーバーエラーが発生しました' }), {
      status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});
