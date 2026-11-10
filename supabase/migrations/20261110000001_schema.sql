-- =====================================================================
-- Gincana de Halloween — 1/3: tabelas, RLS e gatilhos
-- =====================================================================
-- Participantes NÃO têm conta no Supabase: acessam só por funções
-- (migração 2). O administrador usa Supabase Auth e é identificado pela
-- tabela public.admin.

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------
-- Tabelas
-- ---------------------------------------------------------------------

-- Evento: linha única (id = 1)
create table public.evento (
  id           smallint primary key default 1 check (id = 1),
  nome         text not null default 'Gincana de Halloween'
               check (length(btrim(nome)) between 1 and 80),
  aberto       boolean not null default true,
  encerrado_em timestamptz
);
insert into public.evento (id) values (1);

-- O único administrador (id do usuário no Supabase Auth)
create table public.admin (
  user_id uuid primary key
);

create table public.grupo (
  id        uuid primary key default gen_random_uuid(),
  nome      text not null check (length(btrim(nome)) between 1 and 30),
  cor       text not null default '#9b5cff' check (cor ~ '^#[0-9a-fA-F]{6}$'),
  icone     text not null default '🎃' check (length(icone) between 1 and 8),
  criado_em timestamptz not null default now()
);

create table public.pessoa (
  id                 uuid primary key default gen_random_uuid(),
  nome               text not null check (length(btrim(nome)) between 1 and 40),
  grupo_id           uuid references public.grupo(id) on delete set null,
  senha_hash         text,                       -- bcrypt; nunca a senha em texto
  tentativas_erradas integer not null default 0,
  bloqueado_ate      timestamptz,
  criado_em          timestamptz not null default now()
);
create index pessoa_grupo_idx on public.pessoa (grupo_id);

-- Sessão do participante: guarda só o hash (sha256) do token.
-- Vale até o participante tocar em "Sair" (ou o admin trocar a senha).
create table public.sessao (
  token_hash bytea primary key,
  pessoa_id  uuid not null references public.pessoa(id) on delete cascade,
  criado_em  timestamptz not null default now(),
  ultimo_uso timestamptz not null default now()
);
create index sessao_pessoa_idx on public.sessao (pessoa_id);

-- Jogo: formato = modo (quem pontua) × formato (como registra)
create table public.jogo (
  id          uuid primary key default gen_random_uuid(),
  nome        text not null check (length(btrim(nome)) between 1 and 60),
  tipo        text not null default 'Jogo' check (tipo in ('Jogo', 'Gincana')),
  descricao   text not null default '' check (length(descricao) <= 500),
  modo        text not null default 'individual' check (modo in ('individual', 'grupo')),
  formato     text not null default 'vitoria' check (formato in ('vitoria', 'colocacao')),
  -- formato 'vitoria'
  pontos      integer       not null default 10 check (pontos >= 0),
  premio      numeric(10,2) not null default 20 check (premio >= 0),
  -- formato 'colocacao'
  pontos_1    integer       not null default 10 check (pontos_1 >= 0),
  premio_1    numeric(10,2) not null default 20 check (premio_1 >= 0),
  pontos_2    integer       not null default 6  check (pontos_2 >= 0),
  premio_2    numeric(10,2) not null default 10 check (premio_2 >= 0),
  pontos_3    integer       not null default 3  check (pontos_3 >= 0),
  premio_3    numeric(10,2) not null default 5  check (premio_3 >= 0),
  pontuado_em timestamptz,                      -- null = aguardando resultado
  criado_em   timestamptz not null default now()
);

-- Grupos que disputam um jogo "por grupo"
create table public.jogo_grupo (
  jogo_id  uuid not null references public.jogo(id) on delete cascade,
  grupo_id uuid not null references public.grupo(id) on delete cascade,
  primary key (jogo_id, grupo_id)
);

-- Participantes de um jogo "individual"
create table public.participacao (
  jogo_id   uuid not null references public.jogo(id) on delete cascade,
  pessoa_id uuid not null references public.pessoa(id) on delete cascade,
  primary key (jogo_id, pessoa_id)
);
create index participacao_pessoa_idx on public.participacao (pessoa_id);

-- Resultado: uma linha por pessoa que pontuou. Em jogo por grupo, uma linha
-- por membro (foto dos membros no momento do registro), com grupo_id.
-- Empates de colocação são permitidos.
create table public.resultado (
  id            bigint generated always as identity primary key,
  jogo_id       uuid not null references public.jogo(id) on delete cascade,
  pessoa_id     uuid not null references public.pessoa(id) on delete cascade,
  grupo_id      uuid references public.grupo(id) on delete set null,
  colocacao     smallint not null check (colocacao between 1 and 3),
  pontos        integer not null check (pontos >= 0),
  premio        numeric(10,2) not null check (premio >= 0),
  registrado_em timestamptz not null default clock_timestamp(),
  unique (jogo_id, pessoa_id)
);
create index resultado_pessoa_idx on public.resultado (pessoa_id);

-- ---------------------------------------------------------------------
-- Quem é o administrador
-- ---------------------------------------------------------------------
create function public.fn_is_admin()
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (select 1 from public.admin a where a.user_id = auth.uid());
$$;

-- ---------------------------------------------------------------------
-- RLS: ligado em todas as tabelas. Só o admin (authenticated + tabela
-- admin) tem políticas. anon não tem nenhuma. sessao/admin: nenhuma.
-- ---------------------------------------------------------------------
alter table public.evento       enable row level security;
alter table public.admin        enable row level security;
alter table public.grupo        enable row level security;
alter table public.pessoa       enable row level security;
alter table public.sessao       enable row level security;
alter table public.jogo         enable row level security;
alter table public.jogo_grupo   enable row level security;
alter table public.participacao enable row level security;
alter table public.resultado    enable row level security;

create policy evento_admin_le on public.evento
  for select to authenticated using ((select public.fn_is_admin()));
create policy evento_admin_altera on public.evento
  for update to authenticated
  using ((select public.fn_is_admin())) with check ((select public.fn_is_admin()));

create policy grupo_admin on public.grupo
  for all to authenticated
  using ((select public.fn_is_admin())) with check ((select public.fn_is_admin()));
create policy pessoa_admin on public.pessoa
  for all to authenticated
  using ((select public.fn_is_admin())) with check ((select public.fn_is_admin()));
create policy jogo_admin on public.jogo
  for all to authenticated
  using ((select public.fn_is_admin())) with check ((select public.fn_is_admin()));
create policy jogo_grupo_admin on public.jogo_grupo
  for all to authenticated
  using ((select public.fn_is_admin())) with check ((select public.fn_is_admin()));
create policy participacao_admin on public.participacao
  for all to authenticated
  using ((select public.fn_is_admin())) with check ((select public.fn_is_admin()));
-- Resultado: admin só lê direto; grava por fn_admin_registrar_resultado
create policy resultado_admin_le on public.resultado
  for select to authenticated using ((select public.fn_is_admin()));

-- ---------------------------------------------------------------------
-- Gatilho: evento encerrado bloqueia cadastro e pontuação
-- ---------------------------------------------------------------------
create function public.tg_exige_evento_aberto()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if not coalesce((select e.aberto from public.evento e where e.id = 1), true) then
    raise exception 'O evento está encerrado. Reabra o evento para cadastrar ou pontuar.'
      using errcode = 'P0001';
  end if;
  return coalesce(new, old);
end;
$$;

create trigger exige_evento_aberto before insert or update or delete on public.grupo
  for each row execute function public.tg_exige_evento_aberto();
create trigger exige_evento_aberto before insert or update or delete on public.jogo
  for each row execute function public.tg_exige_evento_aberto();
create trigger exige_evento_aberto before insert or update or delete on public.jogo_grupo
  for each row execute function public.tg_exige_evento_aberto();
create trigger exige_evento_aberto before insert or update or delete on public.participacao
  for each row execute function public.tg_exige_evento_aberto();
create trigger exige_evento_aberto before insert or update or delete on public.resultado
  for each row execute function public.tg_exige_evento_aberto();
-- Em pessoa só o cadastro (nome/grupo): login e troca de senha seguem funcionando
create trigger exige_evento_aberto before insert or delete or update of nome, grupo_id on public.pessoa
  for each row execute function public.tg_exige_evento_aberto();

-- ---------------------------------------------------------------------
-- Gatilho: mudar o formato (modo ou formato) de um jogo apaga o resultado
-- ---------------------------------------------------------------------
create function public.tg_jogo_formato_mudou()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.modo is distinct from old.modo or new.formato is distinct from old.formato then
    delete from public.resultado r where r.jogo_id = new.id;
    new.pontuado_em := null;
  end if;
  return new;
end;
$$;

create trigger jogo_formato_mudou before update of modo, formato on public.jogo
  for each row execute function public.tg_jogo_formato_mudou();
