-- DZW: شغّل هذا الملف كاملاً مرة واحدة في Supabase > SQL Editor

-- الأعضاء (يُنشأ الملف الشخصي تلقائياً عند التسجيل)
create table profiles (
  id uuid primary key references auth.users on delete cascade,
  username text unique not null check (char_length(username) between 2 and 24),
  role text not null default 'member' check (role in ('member','admin')),
  created_at timestamptz not null default now()
);

create table rooms (
  id text primary key,
  emoji text,
  name text not null,
  cat text not null,
  descr text,
  read_only boolean not null default false,
  sort int not null default 0
);

create table messages (
  id bigint generated always as identity primary key,
  room_id text not null references rooms on delete cascade,
  user_id uuid not null default auth.uid() references profiles on delete cascade,
  body text not null check (char_length(body) between 1 and 800),
  pinned boolean not null default false,
  created_at timestamptz not null default now()
);
create index on messages (room_id, created_at);

create table applications (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references profiles on delete cascade,
  interest text,
  why text not null check (char_length(why) between 1 and 600),
  created_at timestamptz not null default now()
);

create table site_content (key text primary key, value text not null default '');
insert into site_content (key, value) values ('rules', '');

-- دوال مساعدة
create function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'admin')
$$;

create function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, username)
  values (new.id, coalesce(new.raw_user_meta_data->>'username', 'user' || substr(new.id::text, 1, 6)));
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function handle_new_user();

-- منع الإزعاج: رسالة واحدة كل 3 ثوانٍ لكل عضو
create function limit_messages() returns trigger
language plpgsql as $$
begin
  if exists (select 1 from messages where user_id = new.user_id and created_at > now() - interval '3 seconds') then
    raise exception 'slow_down';
  end if;
  return new;
end $$;
create trigger messages_rate before insert on messages
  for each row execute function limit_messages();

-- قواعد الحماية (RLS)
alter table profiles enable row level security;
alter table rooms enable row level security;
alter table messages enable row level security;
alter table applications enable row level security;
alter table site_content enable row level security;

-- العضو يعدّل اسمه فقط، ولا يستطيع تغيير رتبته
revoke update on profiles from authenticated;
grant update (username) on profiles to authenticated;

create policy "profiles_read" on profiles for select using (true);
create policy "profiles_update_own" on profiles for update to authenticated using (id = auth.uid());

create policy "rooms_read" on rooms for select using (true);
create policy "rooms_admin" on rooms for all to authenticated using (is_admin()) with check (is_admin());

create policy "messages_read" on messages for select using (true);
create policy "messages_insert" on messages for insert to authenticated
  with check (user_id = auth.uid() and (is_admin() or not (select read_only from rooms where id = room_id)));
create policy "messages_delete" on messages for delete to authenticated using (user_id = auth.uid() or is_admin());
create policy "messages_pin" on messages for update to authenticated using (is_admin()) with check (is_admin());

create policy "apps_insert" on applications for insert to authenticated with check (user_id = auth.uid());
create policy "apps_read" on applications for select to authenticated using (user_id = auth.uid() or is_admin());

create policy "content_read" on site_content for select using (true);
create policy "content_admin" on site_content for all to authenticated using (is_admin()) with check (is_admin());

-- الرسائل الفورية
alter publication supabase_realtime add table messages;

-- القنوات الأولية
insert into rooms (id, emoji, name, cat, descr, read_only, sort) values
 ('welcome','👋🏻','welcome','البداية','رحّب بالأعضاء الجدد وعرّف بنفسك.',false,1),
 ('announce','📢','announcements','البداية','إعلانات المشرفين.',true,2),
 ('global','🌍','global-chat','المجتمع','الدردشة العامة لكل الأعضاء.',false,3),
 ('command','🤖','command-bot','المجتمع','قناة تجربة الأوامر والبوت.',false,4),
 ('pictures','📷','pictures','المجتمع','شارك صورك.',false,5),
 ('social','📱','social-media','المجتمع','روابط حساباتك ومنصاتك.',false,6),
 ('videos','🎥','videos','المجتمع','شارك فيديوهاتك.',false,7),
 ('games','🆓','free-games','المجتمع','عروض الألعاب المجانية.',false,8),
 ('needs','📋','what-you-need','المجتمع','اكتب ما تحتاجه من المجتمع.',false,9),
 ('ideas','💡','suggestions','الدعم','اقتراحاتك لتطوير المجتمع.',false,10),
 ('complaints','⚠️','complaints','الدعم','قدّم شكواك للإدارة.',false,11),
 ('wt','⚡','wt-explanation','War Thunder','شروحات ونقاش خاص بلعبة War Thunder.',false,12);
