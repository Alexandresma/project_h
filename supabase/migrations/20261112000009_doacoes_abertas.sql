-- =====================================================================
-- Gincana de Halloween — 9: doações liberadas também com os jogos abertos
-- =====================================================================
-- Os participantes podem apostar entre si durante os jogos: quem perde a
-- aposta transfere um valor para quem ganhou. Por isso fn_doar deixa de
-- exigir o período de jogos encerrado. Continua igual:
--   * quem doa é a pessoa do token (nunca um parâmetro do navegador);
--   * valor > 0, no máximo 2 casas, recado até 60, não doa para si mesmo;
--   * valor ≤ saldo de quem doa, conferido na mesma transação com as duas
--     pessoas travadas;
--   * só dinheiro: pontos, vitórias e ranking não mudam.
-- O leilão (arremates e a função fn_leilao) continua só com o período
-- encerrado.
--
-- Atenção: com os jogos abertos o admin ainda pode alterar resultados; se
-- tirar prêmio de quem já doou, o saldo dessa pessoa pode ficar negativo
-- (o mesmo que já acontecia ao reabrir com o leilão iniciado).

create or replace function public.fn_doar(p_token text, p_para uuid, p_valor numeric, p_recado text)
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_eu     uuid := public.fn_sessao_pessoa(p_token);
  v_saldo  numeric;
  v_recado text := btrim(coalesce(p_recado, ''));
begin
  if p_para is null or p_para = v_eu
     or not exists (select 1 from public.pessoa p where p.id = p_para) then
    raise exception 'Escolha para quem doar.' using errcode = '22023';
  end if;
  if p_valor is null or p_valor <= 0 then
    raise exception 'Informe o valor.' using errcode = '22023';
  end if;
  if p_valor <> round(p_valor, 2) then
    raise exception 'Use no máximo 2 casas decimais no valor.' using errcode = '22023';
  end if;
  if char_length(v_recado) > 60 then
    raise exception 'O recado pode ter até 60 caracteres.' using errcode = '22023';
  end if;

  -- trava as duas pessoas (sempre na mesma ordem, sem deadlock)
  perform 1 from public.pessoa p where p.id in (v_eu, p_para) order by p.id for update;

  select s.saldo into v_saldo from public.fn_saldos() s where s.pessoa_id = v_eu;
  if p_valor > v_saldo then
    raise exception 'Saldo insuficiente: você tem %.',
      'R$ ' || replace(to_char(v_saldo, 'FM999999990.00'), '.', ',')
      using errcode = 'P0001';
  end if;

  insert into public.transferencia (de_pessoa_id, para_pessoa_id, valor, motivo)
  values (v_eu, p_para, p_valor, v_recado);

  return jsonb_build_object('saldo_antes', v_saldo, 'saldo_depois', v_saldo - p_valor);
end;
$$;

-- "create or replace" mantém as permissões; reforça mesmo assim
revoke execute on function public.fn_doar(text, uuid, numeric, text) from public;
grant  execute on function public.fn_doar(text, uuid, numeric, text) to anon, authenticated;
