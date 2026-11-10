-- =====================================================================
-- Gincana de Halloween — 4: o admin sabe quem já tem senha
-- =====================================================================
-- senha_hash continua ilegível para todos; tem_senha só diz se existe.

alter table public.pessoa
  add column tem_senha boolean generated always as (senha_hash is not null) stored;

grant select (tem_senha) on public.pessoa to authenticated;
