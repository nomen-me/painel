/* =============================================================================
 * SYNAPSE — Frente de Loja — Service Worker
 *
 * Ciclo A da especificação offline-first: abertura sem internet, mesmo depois
 * de fechar o navegador ou reiniciar o computador.
 *
 * O QUE ESTE ARQUIVO FAZ
 *   1. No install, guarda em cache os arquivos que compõem a aplicação em si
 *      (o "shell": HTML, manifest, ícones, bibliotecas de CDN).
 *   2. No fetch, responde navegação e arquivos do shell com o que está em
 *      cache primeiro — a página abre instantaneamente, com ou sem rede.
 *   3. NUNCA intercepta chamadas para outros domínios (Ritmo, Harmonia,
 *      Chatwoot) nem qualquer request autenticado. Essas requisições passam
 *      direto pro navegador, sem cache — dado sensível não entra aqui.
 *   4. Uma versão nova instala em segundo plano e FICA ESPERANDO (não troca
 *      sozinha). Só assume quando o operador confirmar pelo banner que o
 *      index.html mostra — nunca no meio de uma venda.
 *
 * O QUE ESTE ARQUIVO NÃO FAZ
 *   Não guarda senha, token, cookie de sessão nem qualquer resposta de API.
 *   Não decide se uma venda foi confirmada — isso é do app (fila do
 *   IndexedDB), este arquivo só garante que o app consiga ABRIR.
 *
 * OPERAÇÃO: a cada deploy que troque o conteúdo do shell (index.html,
 * manifest, ícones), incremente SHELL_VERSION abaixo. Sem isso o navegador
 * não tem como saber que há algo novo pra baixar — é o único gatilho de
 * atualização deste mecanismo, de propósito, sem build step.
 * ============================================================================= */

const SHELL_VERSION = 8; // v8: Fase 1 — núcleo da venda (quantidade direta, consulta rápida, categorias, item genérico, descontos/acréscimos, preço autorizado, cancelar/suspender/recuperar, vendedor, mesa/comanda/senha)
const CACHE_NAME = `synapse-pdv-shell-v${SHELL_VERSION}`;
const RUNTIME_CDN_CACHE = 'synapse-pdv-cdn-runtime'; // não versionado: cresce sozinho, ver fetch()

// Essenciais: se qualquer um destes falhar ao baixar, a instalação do SW
// falha de propósito — sem eles não há shell, e fingir que deu certo
// produziria exatamente a falsa confiança que a Synapse proíbe.
const SHELL_ESSENCIAL = [
  './',
  './index.html',
  './manifest.json',
  './icon-192.png',
  './icon-512.png',
  './icon-512-maskable.png',
  './fflate.js',
];

// Best-effort: bibliotecas de CDN usadas pelo app. Se uma delas não puder
// ser pré-cacheada agora (CORS, instabilidade momentânea), a instalação do
// shell não é bloqueada por isso — elas caem no cache de runtime abaixo na
// primeira vez que forem pedidas com internet disponível.
const SHELL_OPCIONAL = [
  'https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.1/css/all.min.css',
  'https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js',
];

self.addEventListener('install', (event) => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE_NAME);
    await cache.addAll(SHELL_ESSENCIAL); // se isto lançar, o install falha — correto

    await Promise.all(SHELL_OPCIONAL.map(async (url) => {
      try {
        const resp = await fetch(url, { mode: 'cors' });
        if (resp && (resp.ok || resp.type === 'opaque')) await cache.put(url, resp);
      } catch (e) {
        console.warn('[sw] recurso opcional não pré-cacheado agora:', url, e && e.message);
      }
    }));
    // Não chama skipWaiting() aqui de propósito: a versão nova espera até o
    // operador confirmar pelo banner (ver mensagem 'ATIVAR_NOVA_VERSAO' abaixo).
  })());
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    // Remove só caches de shell de versões antigas. IndexedDB (catálogo,
    // fila, caixa, clientes, vendas) não é tocado por este código — vive em
    // storage completamente separado do Cache API, e continua intacto.
    const nomes = await caches.keys();
    await Promise.all(nomes
      .filter(n => n.startsWith('synapse-pdv-shell-') && n !== CACHE_NAME)
      .map(n => caches.delete(n)));
    await self.clients.claim();
  })());
});

self.addEventListener('message', (event) => {
  if (event.data === 'ATIVAR_NOVA_VERSAO') self.skipWaiting();
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  const url = new URL(req.url);

  // Regra central: só respondemos por navegação (abrir/recarregar a página)
  // e pelos próprios arquivos do shell. Qualquer outra coisa — chamadas ao
  // Ritmo, Harmonia, Chatwoot, ou qualquer request autenticado — passa
  // direto pro navegador, sem este SW interferir. Isto não é uma exceção
  // tratada; é a ausência de tratamento, de propósito.
  const ehMesmaOrigem = url.origin === self.location.origin;
  const ehShellLocal = ehMesmaOrigem && SHELL_ESSENCIAL.some(p =>
    url.pathname === '/' || url.pathname.endsWith(p.replace('./', '/')));
  const ehCdnConhecido = SHELL_OPCIONAL.some(u => req.url === u) ||
    url.hostname === 'cdnjs.cloudflare.com';

  if (req.mode === 'navigate') {
    event.respondWith(shellComRevalidacao(req, './index.html'));
    return;
  }
  if (ehShellLocal) {
    event.respondWith(shellComRevalidacao(req, req.url));
    return;
  }
  if (ehCdnConhecido) {
    event.respondWith(cachePrimeiroRuntime(req));
    return;
  }
  // Sem respondWith(): o navegador trata normalmente, sem cache nenhum.
});

// Cache-first com atualização em segundo plano (stale-while-revalidate).
// Abre instantâneo a partir do cache; se houver rede, busca a versão atual
// por baixo dos panos e guarda pra PRÓXIMA abertura — nunca troca o que já
// está na tela, então nunca interrompe uma operação em andamento.
async function shellComRevalidacao(req, chaveCache) {
  const cache = await caches.open(CACHE_NAME);
  const emCache = await cache.match(chaveCache, { ignoreSearch: true });
  const buscaRede = fetch(req).then(resp => {
    if (resp && resp.ok) cache.put(chaveCache, resp.clone());
    return resp;
  }).catch(() => null);

  if (emCache) { buscaRede; return emCache; } // dispara revalidação, mas responde já com o cache
  const daRede = await buscaRede;
  if (daRede) return daRede;
  // Nada em cache e sem rede: só acontece na primeiríssima abertura sem
  // internet, que nunca deveria ocorrer (a instalação exige rede uma vez).
  return new Response(
    '<h1>Synapse — Frente de Loja</h1><p>Primeira abertura precisa de internet, pra preparar o app. Depois disso funciona offline.</p>',
    { status: 503, headers: { 'Content-Type': 'text/html; charset=utf-8' } }
  );
}

// Runtime cache puro: usado por recursos externos (CDN) que não sabemos
// listar por completo de antemão (ex.: os arquivos de fonte do Font
// Awesome, referenciados de dentro do CSS, cada um com sua própria URL).
// Primeira vez com internet: busca e guarda. Depois: sempre do cache.
async function cachePrimeiroRuntime(req) {
  const cache = await caches.open(RUNTIME_CDN_CACHE);
  const emCache = await cache.match(req);
  if (emCache) return emCache;
  try {
    const resp = await fetch(req, { mode: 'cors' });
    if (resp && (resp.ok || resp.type === 'opaque')) cache.put(req, resp.clone());
    return resp;
  } catch (e) {
    return emCache || Response.error();
  }
}
