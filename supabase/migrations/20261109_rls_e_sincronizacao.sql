-- =====================================================================
-- Segurança por usuário (RLS) + base da sincronização entre dispositivos
-- Backup prévio: schema "backup" (tabelas *_20261109)
-- =====================================================================

-- 1) Coluna de dono em todas as tabelas da aplicação
do $$
declare t text;
begin
  foreach t in array array['configuracoes','materias','topicos','questoes','sessoes','revisoes','flashcards','cronograma_metas','cartoes','baterias','app_estado'] loop
    execute format('alter table public.%I add column if not exists user_id uuid references auth.users(id) on delete cascade', t);
    execute format('alter table public.%I alter column user_id set default auth.uid()', t);
    execute format('create index if not exists %I on public.%I(user_id)', t || '_user_id_idx', t);
  end loop;
end $$;

-- 2) Chaves passam a ser por usuário: (user_id, id). FKs passam a ser compostas.
alter table public.flashcards drop constraint flashcards_id_materia_fkey;
alter table public.flashcards drop constraint flashcards_id_topico_fkey;
alter table public.questoes   drop constraint questoes_id_topico_fkey;
alter table public.questoes   drop constraint questoes_id_materia_fkey;
alter table public.revisoes   drop constraint revisoes_id_materia_fkey;
alter table public.revisoes   drop constraint revisoes_id_topico_fkey;
alter table public.sessoes    drop constraint sessoes_id_topico_fkey;
alter table public.sessoes    drop constraint sessoes_id_materia_fkey;
alter table public.topicos    drop constraint topicos_id_materia_fkey;

alter table public.configuracoes    drop constraint configuracoes_pkey;
alter table public.materias         drop constraint materias_pkey;
alter table public.topicos          drop constraint topicos_pkey;
alter table public.questoes         drop constraint questoes_pkey;
alter table public.sessoes          drop constraint sessoes_pkey;
alter table public.revisoes         drop constraint revisoes_pkey;
alter table public.flashcards       drop constraint flashcards_pkey;
alter table public.cronograma_metas drop constraint cronograma_metas_pkey;
alter table public.cartoes          drop constraint cartoes_pkey;
alter table public.baterias         drop constraint baterias_pkey;
alter table public.app_estado       drop constraint app_estado_pkey;

alter table public.configuracoes    add constraint configuracoes_usuario_chave_key unique nulls not distinct (user_id, chave);
alter table public.materias         add constraint materias_usuario_id_key         unique nulls not distinct (user_id, id);
alter table public.topicos          add constraint topicos_usuario_id_key          unique nulls not distinct (user_id, id);
alter table public.questoes         add constraint questoes_usuario_id_key         unique nulls not distinct (user_id, id);
alter table public.sessoes          add constraint sessoes_usuario_id_key          unique nulls not distinct (user_id, id);
alter table public.revisoes         add constraint revisoes_usuario_id_key         unique nulls not distinct (user_id, id);
alter table public.flashcards       add constraint flashcards_usuario_id_key       unique nulls not distinct (user_id, id);
alter table public.cronograma_metas add constraint cronograma_metas_usuario_id_key unique nulls not distinct (user_id, id);
alter table public.cartoes          add constraint cartoes_usuario_id_key          unique nulls not distinct (user_id, id);
alter table public.baterias         add constraint baterias_usuario_id_key         unique nulls not distinct (user_id, id);
alter table public.app_estado       add constraint app_estado_usuario_id_key       unique nulls not distinct (user_id, id);

alter table public.topicos    add constraint topicos_id_materia_fkey    foreign key (user_id, id_materia) references public.materias(user_id, id) on delete cascade;
alter table public.flashcards add constraint flashcards_id_materia_fkey foreign key (user_id, id_materia) references public.materias(user_id, id) on delete set null (id_materia);
alter table public.flashcards add constraint flashcards_id_topico_fkey  foreign key (user_id, id_topico)  references public.topicos(user_id, id)  on delete set null (id_topico);
alter table public.questoes   add constraint questoes_id_topico_fkey    foreign key (user_id, id_topico)  references public.topicos(user_id, id)  on delete cascade;
alter table public.questoes   add constraint questoes_id_materia_fkey   foreign key (user_id, id_materia) references public.materias(user_id, id) on delete cascade;
alter table public.revisoes   add constraint revisoes_id_materia_fkey   foreign key (user_id, id_materia) references public.materias(user_id, id) on delete cascade;
alter table public.revisoes   add constraint revisoes_id_topico_fkey    foreign key (user_id, id_topico)  references public.topicos(user_id, id)  on delete cascade;
alter table public.sessoes    add constraint sessoes_id_topico_fkey     foreign key (user_id, id_topico)  references public.topicos(user_id, id)  on delete cascade;
alter table public.sessoes    add constraint sessoes_id_materia_fkey    foreign key (user_id, id_materia) references public.materias(user_id, id) on delete cascade;

-- 3) Documentos de progresso (tabela configuracoes) ganham versão para gravação sem sobrescrita
alter table public.configuracoes add column if not exists versao bigint not null default 0;
alter table public.configuracoes add column if not exists atualizado_em timestamptz not null default now();

-- 4) Dono sempre = usuário autenticado (impede gravar em nome de outro)
create or replace function public.definir_dono_registro()
returns trigger language plpgsql set search_path = '' as $$
begin
  if auth.uid() is not null then
    new.user_id := auth.uid();
  end if;
  return new;
end $$;

-- 5) Controle de alterações por dispositivo (para os outros aparelhos se atualizarem sozinhos)
create table if not exists public.sync_estado (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  dispositivo text not null,
  versao bigint not null default 0,
  atualizado_em timestamptz not null default now(),
  primary key (user_id, dispositivo)
);

create or replace function public.registrar_alteracao_sync()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_disp text;
begin
  if v_uid is null then return null; end if;
  /* uma marca por transação basta */
  if current_setting('gr.sync_marcado', true) = '1' then return null; end if;
  perform set_config('gr.sync_marcado', '1', true);
  begin
    v_disp := nullif(left(coalesce(current_setting('request.headers', true)::json->>'x-dispositivo', ''), 64), '');
  exception when others then v_disp := null;
  end;
  insert into public.sync_estado(user_id, dispositivo, versao, atualizado_em)
  values (v_uid, coalesce(v_disp, 'desconhecido'), 1, now())
  on conflict (user_id, dispositivo) do update set versao = public.sync_estado.versao + 1, atualizado_em = now();
  return null;
end $$;
revoke all on function public.registrar_alteracao_sync() from public, anon, authenticated;

do $$
declare t text;
begin
  foreach t in array array['configuracoes','materias','topicos','questoes','sessoes','revisoes','flashcards','cronograma_metas','cartoes','baterias','app_estado'] loop
    execute format('drop trigger if exists tg_definir_dono on public.%I', t);
    execute format('create trigger tg_definir_dono before insert or update on public.%I for each row execute function public.definir_dono_registro()', t);
    execute format('drop trigger if exists tg_registrar_alteracao on public.%I', t);
    execute format('drop trigger if exists tg_registrar_alteracao_ins on public.%I', t);
    execute format('create trigger tg_registrar_alteracao_ins after insert or delete on public.%I for each row execute function public.registrar_alteracao_sync()', t);
    execute format('drop trigger if exists tg_registrar_alteracao_upd on public.%I', t);
    execute format('create trigger tg_registrar_alteracao_upd after update on public.%I for each row when (old.* is distinct from new.*) execute function public.registrar_alteracao_sync()', t);
  end loop;
end $$;

-- 6) RLS + políticas por operação em todas as tabelas
do $$
declare t text;
begin
  foreach t in array array['configuracoes','materias','topicos','questoes','sessoes','revisoes','flashcards','cronograma_metas','cartoes','baterias','app_estado','sync_estado'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
    execute format('drop policy if exists %I on public.%I', t || '_select_proprio', t);
    execute format('drop policy if exists %I on public.%I', t || '_insert_proprio', t);
    execute format('drop policy if exists %I on public.%I', t || '_update_proprio', t);
    execute format('drop policy if exists %I on public.%I', t || '_delete_proprio', t);
    execute format('create policy %I on public.%I for select to authenticated using ((select auth.uid()) = user_id)', t || '_select_proprio', t);
    execute format('create policy %I on public.%I for insert to authenticated with check ((select auth.uid()) = user_id)', t || '_insert_proprio', t);
    execute format('create policy %I on public.%I for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id)', t || '_update_proprio', t);
    execute format('create policy %I on public.%I for delete to authenticated using ((select auth.uid()) = user_id)', t || '_delete_proprio', t);
  end loop;
end $$;
revoke all on all sequences in schema public from anon;

-- 7) Gravação de documento com controle de versão (sem sobrescrever alteração de outro aparelho)
create or replace function public.salvar_documento(p_chave text, p_valor text, p_versao_esperada bigint)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_versao bigint;
begin
  if v_uid is null then raise exception 'nao autenticado' using errcode = '42501'; end if;
  update public.configuracoes
     set valor = p_valor, versao = versao + 1, atualizado_em = now()
   where user_id = v_uid and chave = p_chave and versao = p_versao_esperada
  returning versao into v_versao;
  if found then return jsonb_build_object('ok', true, 'versao', v_versao); end if;
  if not exists (select 1 from public.configuracoes where user_id = v_uid and chave = p_chave) then
    insert into public.configuracoes(user_id, chave, valor, descricao, versao, atualizado_em)
    values (v_uid, p_chave, p_valor, 'Documento de progresso sincronizado', 1, now())
    on conflict do nothing;
    if found then return jsonb_build_object('ok', true, 'versao', 1); end if;
  end if;
  select versao into v_versao from public.configuracoes where user_id = v_uid and chave = p_chave;
  return jsonb_build_object('ok', false, 'versao', coalesce(v_versao, 0));
end $$;
revoke all on function public.salvar_documento(text, text, bigint) from public, anon;
grant execute on function public.salvar_documento(text, text, bigint) to authenticated;

-- 8) Transferência única dos dados existentes (sem dono) para a conta do proprietário
create or replace function public.reivindicar_dados_legados()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_email text; v_conf timestamptz;
  v_res jsonb := '{}'::jsonb; v_n bigint; t text;
begin
  if v_uid is null then return jsonb_build_object('ok', false, 'motivo', 'nao autenticado'); end if;
  select lower(email), email_confirmed_at into v_email, v_conf from auth.users where id = v_uid;
  if v_email is distinct from 'davioliiveira0525@gmail.com' or v_conf is null then
    return jsonb_build_object('ok', false, 'motivo', 'conta nao e a proprietaria dos dados antigos');
  end if;
  foreach t in array array['materias','topicos','configuracoes','questoes','sessoes','revisoes','flashcards','cronograma_metas','cartoes','baterias','app_estado'] loop
    /* se a conta já criou registros com a mesma chave (ex.: configurações padrão), prevalecem os dados antigos */
    execute format('delete from public.%1$I d where d.user_id = $1 and exists (select 1 from public.%1$I o where o.user_id is null and o.%2$I = d.%2$I)', t, case when t = 'configuracoes' then 'chave' else 'id' end) using v_uid;
    execute format('update public.%I set user_id = $1 where user_id is null', t) using v_uid;
    get diagnostics v_n = row_count;
    v_res := v_res || jsonb_build_object(t, v_n);
  end loop;
  return jsonb_build_object('ok', true, 'transferidos', v_res);
end $$;
revoke all on function public.reivindicar_dados_legados() from public, anon;
grant execute on function public.reivindicar_dados_legados() to authenticated;
