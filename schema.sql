-- ============================================================
-- سوق الجملة – Supabase schema (v1)
-- Run in: Supabase Dashboard → SQL Editor
-- ============================================================

create extension if not exists pg_trgm;

-- ---------- ENUMS ----------
create type user_role   as enum ('supplier', 'shop_owner', 'admin');
create type store_status as enum ('pending', 'approved', 'suspended');

-- ---------- REFERENCE TABLES ----------
create table wilayas (
  id      smallint primary key,            -- official wilaya code (1..69)
  name_ar text not null,
  name_fr text
);

create table categories (
  id        serial primary key,
  parent_id int references categories(id) on delete set null,
  name_ar   text not null,
  name_fr   text,
  icon      text,
  sort      int not null default 0
);

-- ---------- PROFILES (linked to Supabase Auth, no password here) ----------
create table profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  full_name  text not null default '',
  phone      text,
  role       user_role not null default 'shop_owner',
  is_blocked boolean not null default false,
  created_at timestamptz not null default now()
);

-- Helper: is the current user an admin?
create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'admin' and not is_blocked);
$$;

-- Auto-create profile on signup. Admin role can never be self-assigned.
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, full_name, phone, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', ''),
    new.raw_user_meta_data->>'phone',
    case when new.raw_user_meta_data->>'role' = 'supplier'
         then 'supplier'::user_role else 'shop_owner'::user_role end
  );
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users for each row execute function handle_new_user();

-- ---------- STORES ----------
create table stores (
  id             uuid primary key default gen_random_uuid(),
  owner_id       uuid not null unique references profiles(id) on delete cascade,
  name           text not null check (char_length(name) between 2 and 80),
  description    text check (char_length(description) <= 1000),
  logo_url       text,
  wilaya_id      smallint not null references wilayas(id),
  address        text,
  -- Algerian mobile in international format without "+": 213 + 5/6/7 + 8 digits
  whatsapp_phone text not null check (whatsapp_phone ~ '^213[567][0-9]{8}$'),
  -- MVP: active immediately. To require admin review, change default to 'pending'.
  status         store_status not null default 'approved',
  created_at     timestamptz not null default now()
);
create index on stores (wilaya_id);
create index on stores (status);

-- Wilayas each store delivers to (many-to-many)
create table store_delivery_wilayas (
  store_id  uuid     not null references stores(id) on delete cascade,
  wilaya_id smallint not null references wilayas(id),
  primary key (store_id, wilaya_id)
);

-- ---------- PRODUCTS ----------
create table products (
  id               uuid primary key default gen_random_uuid(),
  store_id         uuid not null references stores(id) on delete cascade,
  category_id      int  not null references categories(id),
  name             text not null check (char_length(name) between 2 and 120),
  description      text check (char_length(description) <= 2000),
  carton_price     numeric(12,2) not null check (carton_price > 0),   -- DZD
  units_per_carton int  not null default 1 check (units_per_carton > 0),
  min_qty_cartons  int  not null default 1 check (min_qty_cartons > 0),
  stock_cartons    int  not null default 0 check (stock_cartons >= 0),
  is_active        boolean not null default true,
  is_hidden_by_admin boolean not null default false,
  created_at       timestamptz not null default now(),
  -- derived unit price
  unit_price numeric(12,2) generated always as (round(carton_price / units_per_carton, 2)) stored
);
create index on products (store_id);
create index on products (category_id);
create index on products (carton_price);
create index on products (created_at desc);
create index products_name_trgm on products using gin (name gin_trgm_ops);

create table product_images (
  id         uuid primary key default gen_random_uuid(),
  product_id uuid not null references products(id) on delete cascade,
  url        text not null,
  sort       int  not null default 0
);
create index on product_images (product_id);

-- ---------- FAVORITES (phase 2, table ready) ----------
create table favorites (
  user_id    uuid not null references profiles(id) on delete cascade,
  product_id uuid not null references products(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, product_id)
);

-- ---------- WHATSAPP CLICK TRACKING (KPI) ----------
create table whatsapp_clicks (
  id         bigint generated always as identity primary key,
  product_id uuid references products(id) on delete set null,
  store_id   uuid not null references stores(id) on delete cascade,
  buyer_id   uuid references profiles(id) on delete set null,   -- null = guest
  wilaya_id  smallint references wilayas(id),
  quantity   int check (quantity > 0),
  created_at timestamptz not null default now()
);
create index on whatsapp_clicks (store_id, created_at desc);

-- ---------- ADMIN LOG ----------
create table admin_logs (
  id         bigint generated always as identity primary key,
  admin_id   uuid not null references profiles(id),
  action     text not null,            -- e.g. 'approve_store', 'hide_product'
  target     text,
  created_at timestamptz not null default now()
);

-- ============================================================
-- PUBLIC VIEW: only visible products from approved stores
-- ============================================================
create view products_public with (security_invoker = false) as
select p.id, p.name, p.description, p.carton_price, p.unit_price, p.units_per_carton,
       p.min_qty_cartons, p.stock_cartons, p.category_id, p.created_at,
       s.id as store_id, s.name as store_name, s.logo_url, s.wilaya_id as store_wilaya_id,
       s.whatsapp_phone,
       (select url from product_images i where i.product_id = p.id order by sort limit 1) as image_url
from products p
join stores s on s.id = p.store_id
where p.is_active and not p.is_hidden_by_admin and s.status = 'approved';

grant select on products_public to anon, authenticated;

-- ============================================================
-- SEARCH FUNCTION (used by the search page)
-- delivers_to: only stores delivering to this wilaya (null = all)
-- ============================================================
create or replace function search_products(
  q            text    default null,
  delivers_to  smallint default null,
  cat_id       int     default null,
  max_price    numeric default null,
  lim          int     default 24,
  off          int     default 0
) returns setof products_public
language sql stable as $$
  select * from products_public pp
  where (q is null or q = '' or pp.name ilike '%' || q || '%' or pp.store_name ilike '%' || q || '%')
    and (cat_id is null or pp.category_id = cat_id
         or pp.category_id in (select id from categories where parent_id = cat_id))
    and (max_price is null or pp.carton_price <= max_price)
    and (delivers_to is null or exists (
          select 1 from store_delivery_wilayas d
          where d.store_id = pp.store_id and d.wilaya_id = delivers_to))
  order by pp.created_at desc
  limit lim offset off;
$$;

-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================
alter table wilayas               enable row level security;
alter table categories            enable row level security;
alter table profiles              enable row level security;
alter table stores                enable row level security;
alter table store_delivery_wilayas enable row level security;
alter table products              enable row level security;
alter table product_images        enable row level security;
alter table favorites             enable row level security;
alter table whatsapp_clicks       enable row level security;
alter table admin_logs            enable row level security;

-- Reference data: public read, admin write
create policy "wilayas read"  on wilayas    for select using (true);
create policy "wilayas admin" on wilayas    for all using (is_admin()) with check (is_admin());
create policy "cats read"     on categories for select using (true);
create policy "cats admin"    on categories for all using (is_admin()) with check (is_admin());

-- Profiles: own row or admin. Users cannot change their own role / block flag.
create policy "profile self read"   on profiles for select using (id = auth.uid() or is_admin());
create policy "profile self update" on profiles for update using (id = auth.uid())
  with check (id = auth.uid()
    and role = (select role from profiles where id = auth.uid())
    and is_blocked = false);
create policy "profile admin all"   on profiles for all using (is_admin()) with check (is_admin());

-- Stores: approved are public; owners manage their own; admin manages all
create policy "stores public read" on stores for select
  using (status = 'approved' or owner_id = auth.uid() or is_admin());
create policy "stores owner insert" on stores for insert
  with check (owner_id = auth.uid()
    and exists (select 1 from profiles where id = auth.uid() and role = 'supplier' and not is_blocked));
create policy "stores owner update" on stores for update
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy "stores admin all" on stores for all using (is_admin()) with check (is_admin());

-- Block owners from self-approving: status can only be changed by admin
create or replace function protect_store_status() returns trigger
language plpgsql as $$
begin
  if new.status is distinct from old.status and not is_admin() then
    raise exception 'Only admins can change store status';
  end if;
  return new;
end $$;
create trigger trg_protect_store_status before update on stores
  for each row execute function protect_store_status();

-- Delivery wilayas
create policy "delivery read" on store_delivery_wilayas for select using (true);
create policy "delivery owner write" on store_delivery_wilayas for all
  using (exists (select 1 from stores s where s.id = store_id and s.owner_id = auth.uid()))
  with check (exists (select 1 from stores s where s.id = store_id and s.owner_id = auth.uid()));

-- Products
create policy "products owner all" on products for all
  using (exists (select 1 from stores s where s.id = store_id and s.owner_id = auth.uid()))
  with check (exists (select 1 from stores s where s.id = store_id and s.owner_id = auth.uid()));
create policy "products admin all" on products for all using (is_admin()) with check (is_admin());

create policy "images read" on product_images for select using (true);
create policy "images owner write" on product_images for all
  using (exists (select 1 from products p join stores s on s.id = p.store_id
                 where p.id = product_id and s.owner_id = auth.uid()))
  with check (exists (select 1 from products p join stores s on s.id = p.store_id
                 where p.id = product_id and s.owner_id = auth.uid()));

-- Favorites
create policy "fav own" on favorites for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- WhatsApp clicks: anyone may log a click; only the store owner / admin can read
create policy "clicks insert" on whatsapp_clicks for insert
  with check (buyer_id is null or buyer_id = auth.uid());
create policy "clicks read" on whatsapp_clicks for select
  using (is_admin() or exists (select 1 from stores s where s.id = store_id and s.owner_id = auth.uid()));

create policy "logs admin" on admin_logs for all using (is_admin()) with check (is_admin());

-- ============================================================
-- ADMIN STATS VIEW (admin dashboard)
-- ============================================================
create view admin_stats with (security_invoker = true) as
select
  (select count(*) from profiles where role = 'supplier')                        as suppliers,
  (select count(*) from profiles where role = 'shop_owner')                      as shop_owners,
  (select count(*) from stores   where status = 'pending')                       as pending_stores,
  (select count(*) from products where is_active)                                as active_products,
  (select count(*) from whatsapp_clicks where created_at > now() - interval '7 days')  as clicks_7d,
  (select count(*) from whatsapp_clicks where created_at > now() - interval '30 days') as clicks_30d;

-- ============================================================
-- STORAGE (images)  – folder name must equal the uploader's user id
-- ============================================================
insert into storage.buckets (id, name, public) values
  ('product-images', 'product-images', true),
  ('store-logos',    'store-logos',    true)
on conflict do nothing;

create policy "public read images" on storage.objects for select
  using (bucket_id in ('product-images', 'store-logos'));
create policy "owner upload images" on storage.objects for insert to authenticated
  with check (bucket_id in ('product-images', 'store-logos')
              and (storage.foldername(name))[1] = auth.uid()::text);
create policy "owner delete images" on storage.objects for delete to authenticated
  using (bucket_id in ('product-images', 'store-logos')
         and (storage.foldername(name))[1] = auth.uid()::text);

-- ============================================================
-- SEED: 69 WILAYAS (law 06-26, April 2026)
-- ============================================================
insert into wilayas (id, name_ar) values
(1,'أدرار'),(2,'الشلف'),(3,'الأغواط'),(4,'أم البواقي'),(5,'باتنة'),(6,'بجاية'),(7,'بسكرة'),
(8,'بشار'),(9,'البليدة'),(10,'البويرة'),(11,'تمنراست'),(12,'تبسة'),(13,'تلمسان'),(14,'تيارت'),
(15,'تيزي وزو'),(16,'الجزائر'),(17,'الجلفة'),(18,'جيجل'),(19,'سطيف'),(20,'سعيدة'),
(21,'سكيكدة'),(22,'سيدي بلعباس'),(23,'عنابة'),(24,'قالمة'),(25,'قسنطينة'),(26,'المدية'),
(27,'مستغانم'),(28,'المسيلة'),(29,'معسكر'),(30,'ورقلة'),(31,'وهران'),(32,'البيض'),
(33,'إليزي'),(34,'برج بوعريريج'),(35,'بومرداس'),(36,'الطارف'),(37,'تندوف'),(38,'تيسمسيلت'),
(39,'الوادي'),(40,'خنشلة'),(41,'سوق أهراس'),(42,'تيبازة'),(43,'ميلة'),(44,'عين الدفلى'),
(45,'النعامة'),(46,'عين تموشنت'),(47,'غرداية'),(48,'غليزان'),(49,'تيميمون'),
(50,'برج باجي مختار'),(51,'أولاد جلال'),(52,'بني عباس'),(53,'عين صالح'),(54,'عين قزام'),
(55,'تقرت'),(56,'جانت'),(57,'المغير'),(58,'المنيعة'),
(59,'آفلو'),(60,'بريكة'),(61,'القنطرة'),(62,'بئر العاتر'),(63,'العريشة'),(64,'قصر الشلالة'),
(65,'عين وسارة'),(66,'مسعد'),(67,'قصر البخاري'),(68,'بوسعادة'),(69,'الأبيض سيدي الشيخ');

-- ⚠ Verify codes 59–69 against the official gazette order before launch.

insert into categories (name_ar, name_fr, icon, sort) values
('مواد غذائية','Alimentaire','🛒',1),
('مشروبات','Boissons','🥤',2),
('منظفات','Produits ménagers','🧴',3),
('إلكترونيات','Électronique','🔌',4),
('ألبسة','Vêtements','👕',5),
('أدوات مكتبية','Papeterie','📚',6);

-- ============================================================
-- AFTER FIRST SIGNUP: make yourself admin (run once, replace the email)
-- update profiles set role = 'admin'
--   where id = (select id from auth.users where email = 'you@example.com');
-- ============================================================

-- ============================================================
-- ============================================================
-- SECURITY HARDENING (v1.1)  — idempotent: if you already ran
-- the schema above, you can run ONLY this section.
-- ============================================================
-- ============================================================

-- ---------- helpers ----------
create or replace function is_blocked_user(uid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_blocked from profiles where id = uid), true);
$$;

create or replace function is_active_supplier() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'supplier' and not is_blocked);
$$;

create or replace function email_confirmed() returns boolean
language sql stable security definer set search_path = public, auth as $$
  select exists (select 1 from auth.users where id = auth.uid() and email_confirmed_at is not null);
$$;

-- ---------- profiles: nobody but an admin can change role / is_blocked ----------
-- (fixes: a blocked user could un-block themselves)
drop policy if exists "profile self update" on profiles;
create policy "profile self update" on profiles for update
  using (id = auth.uid()) with check (id = auth.uid());

create or replace function protect_profile() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not is_admin()
     and (new.role is distinct from old.role or new.is_blocked is distinct from old.is_blocked) then
    raise exception 'Not allowed';
  end if;
  return new;
end $$;
drop trigger if exists trg_protect_profile on profiles;
create trigger trg_protect_profile before update on profiles
  for each row execute function protect_profile();

-- ---------- stores ----------
-- New stores ALWAYS start as 'pending' (a supplier can never self-approve).
alter table stores alter column status set default 'pending';

create or replace function protect_store_status() returns trigger
language plpgsql set search_path = public as $$
begin
  if auth.uid() is not null and not is_admin() then   -- SQL Editor (no JWT) is allowed
    if tg_op = 'INSERT' then
      new.status := 'pending';
    elsif new.status is distinct from old.status then
      raise exception 'Only admins can change store status';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_protect_store_status on stores;
create trigger trg_protect_store_status before insert or update on stores
  for each row execute function protect_store_status();

-- The stores table is private (owner / admin). Public pages use stores_public (no owner_id).
drop policy if exists "stores public read"  on stores;
drop policy if exists "stores owner read"   on stores;
create policy "stores owner read" on stores for select using (owner_id = auth.uid() or is_admin());

drop policy if exists "stores owner insert" on stores;
create policy "stores owner insert" on stores for insert
  with check (owner_id = auth.uid() and is_active_supplier() and email_confirmed());

drop policy if exists "stores owner update" on stores;
create policy "stores owner update" on stores for update
  using (owner_id = auth.uid() and is_active_supplier()) with check (owner_id = auth.uid());

create or replace view stores_public with (security_invoker = false) as
select s.id, s.name, s.description, s.logo_url, s.wilaya_id, s.address, s.whatsapp_phone, s.created_at
from stores s
where s.status = 'approved' and not is_blocked_user(s.owner_id);
grant select on stores_public to anon, authenticated;

-- Image URLs must point to this project's storage (no external tracking images)
alter table stores drop constraint if exists stores_logo_chk;
alter table stores add constraint stores_logo_chk check (logo_url is null or
  logo_url ~ '^https://[a-z0-9-]+\.supabase\.co/storage/v1/object/public/store-logos/');
alter table product_images drop constraint if exists product_images_url_chk;
alter table product_images add constraint product_images_url_chk check (
  url ~ '^https://[a-z0-9-]+\.supabase\.co/storage/v1/object/public/product-images/');
-- (custom Supabase domain? adapt the two regexes above)

-- ---------- delivery wilayas / products / images: active suppliers only ----------
drop policy if exists "delivery owner write" on store_delivery_wilayas;
create policy "delivery owner write" on store_delivery_wilayas for all
  using (is_active_supplier() and exists (select 1 from stores s where s.id = store_id and s.owner_id = auth.uid()))
  with check (is_active_supplier() and exists (select 1 from stores s where s.id = store_id and s.owner_id = auth.uid()));

drop policy if exists "products owner all" on products;
create policy "products owner all" on products for all
  using (is_active_supplier() and exists (select 1 from stores s where s.id = store_id and s.owner_id = auth.uid()))
  with check (is_active_supplier() and exists (select 1 from stores s where s.id = store_id and s.owner_id = auth.uid()));

drop policy if exists "images owner write" on product_images;
create policy "images owner write" on product_images for all
  using (is_active_supplier() and exists (select 1 from products p join stores s on s.id = p.store_id
         where p.id = product_id and s.owner_id = auth.uid()))
  with check (is_active_supplier() and exists (select 1 from products p join stores s on s.id = p.store_id
         where p.id = product_id and s.owner_id = auth.uid()));

-- Suppliers can never touch is_hidden_by_admin; cap products per store (300)
create or replace function protect_product() returns trigger
language plpgsql set search_path = public as $$
begin
  if auth.uid() is not null and not is_admin() then
    if tg_op = 'INSERT' then new.is_hidden_by_admin := false;
    elsif new.is_hidden_by_admin is distinct from old.is_hidden_by_admin then
      raise exception 'Not allowed';
    end if;
  end if;
  if tg_op = 'INSERT' and (select count(*) from products where store_id = new.store_id) >= 300 then
    raise exception 'Product limit reached';
  end if;
  return new;
end $$;
drop trigger if exists trg_protect_product on products;
create trigger trg_protect_product before insert or update on products
  for each row execute function protect_product();

-- Cap images per product (6)
create or replace function limit_product_images() returns trigger
language plpgsql set search_path = public as $$
begin
  if (select count(*) from product_images where product_id = new.product_id) >= 6 then
    raise exception 'Max 6 images per product';
  end if;
  return new;
end $$;
drop trigger if exists trg_limit_images on product_images;
create trigger trg_limit_images before insert on product_images
  for each row execute function limit_product_images();

-- Public view: also hides products of blocked owners
create or replace view products_public with (security_invoker = false) as
select p.id, p.name, p.description, p.carton_price, p.unit_price, p.units_per_carton,
       p.min_qty_cartons, p.stock_cartons, p.category_id, p.created_at,
       s.id as store_id, s.name as store_name, s.logo_url, s.wilaya_id as store_wilaya_id,
       s.whatsapp_phone,
       (select url from product_images i where i.product_id = p.id order by sort limit 1) as image_url
from products p
join stores s on s.id = p.store_id
where p.is_active and not p.is_hidden_by_admin and s.status = 'approved'
  and not is_blocked_user(s.owner_id);

-- ---------- search: hard caps on page size / query length ----------
create or replace function search_products(
  q text default null, delivers_to smallint default null, cat_id int default null,
  max_price numeric default null, lim int default 24, off int default 0
) returns setof products_public
language sql stable set search_path = public as $$
  select * from products_public pp
  where (q is null or q = '' or pp.name ilike '%' || left(q, 60) || '%' or pp.store_name ilike '%' || left(q, 60) || '%')
    and (cat_id is null or pp.category_id = cat_id
         or pp.category_id in (select id from categories where parent_id = cat_id))
    and (max_price is null or pp.carton_price <= max_price)
    and (delivers_to is null or exists (
          select 1 from store_delivery_wilayas d
          where d.store_id = pp.store_id and d.wilaya_id = delivers_to))
  order by pp.created_at desc
  limit least(greatest(coalesce(lim, 24), 1), 48)
  offset greatest(coalesce(off, 0), 0);
$$;

-- ---------- WhatsApp clicks: only through a rate-limited function ----------
alter table whatsapp_clicks add column if not exists ip_hash text;
create index if not exists whatsapp_clicks_ip on whatsapp_clicks (ip_hash, created_at desc);
drop policy if exists "clicks insert" on whatsapp_clicks;
revoke insert on whatsapp_clicks from anon, authenticated;

create or replace function log_whatsapp_click(p_product uuid, p_wilaya smallint default null, p_qty int default null)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  sid uuid; hd json; ip text; h text;
begin
  select store_id into sid from products_public where id = p_product;
  if sid is null then return false; end if;
  hd := coalesce(nullif(current_setting('request.headers', true), '')::json, '{}'::json);
  ip := coalesce(hd->>'cf-connecting-ip', hd->>'x-real-ip');
  if ip is not null or auth.uid() is not null then
    h := md5(coalesce(ip, '') || coalesce(auth.uid()::text, ''));
    if (select count(*) from whatsapp_clicks where ip_hash = h and created_at > now() - interval '1 hour') >= 40 then return false; end if;
    if exists (select 1 from whatsapp_clicks where ip_hash = h and product_id = p_product
               and created_at > now() - interval '1 minute') then return false; end if;
  end if;
  insert into whatsapp_clicks (product_id, store_id, buyer_id, wilaya_id, quantity, ip_hash)
  values (p_product, sid, auth.uid(), p_wilaya, least(greatest(coalesce(p_qty, 1), 1), 100000), h);
  return true;
end $$;
revoke execute on function log_whatsapp_click(uuid, smallint, int) from public;
grant  execute on function log_whatsapp_click(uuid, smallint, int) to anon, authenticated;

-- ---------- STORAGE: server-side limits ----------
update storage.buckets
   set file_size_limit = 3145728,
       allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp']   -- no SVG / HTML
 where id in ('product-images', 'store-logos');

-- Public buckets serve files by URL without a SELECT policy; dropping it stops anyone LISTING files/user ids.
drop policy if exists "public read images" on storage.objects;

create or replace function can_upload(b text) returns boolean
language sql stable security definer set search_path = public, storage as $$
  select is_active_supplier() and (
    select count(*) from storage.objects o
    where o.bucket_id = b and (storage.foldername(o.name))[1] = auth.uid()::text
  ) < (case b when 'store-logos' then 10 else 300 end);
$$;

drop policy if exists "owner upload images" on storage.objects;
create policy "owner upload images" on storage.objects for insert to authenticated
  with check (bucket_id in ('product-images', 'store-logos')
              and (storage.foldername(name))[1] = auth.uid()::text
              and can_upload(bucket_id));

-- ---------- ATOMIC SAVES (all-or-nothing) ----------
create or replace function save_store(
  p_name text, p_desc text, p_wilaya smallint, p_address text,
  p_phone text, p_logo text, p_delivery smallint[]
) returns uuid language plpgsql set search_path = public as $$
declare sid uuid;
begin
  if not email_confirmed() then raise exception 'يرجى تأكيد بريدك الإلكتروني أولاً'; end if;
  insert into stores (owner_id, name, description, wilaya_id, address, whatsapp_phone, logo_url)
  values (auth.uid(), p_name, p_desc, p_wilaya, p_address, p_phone, p_logo)
  on conflict (owner_id) do update set
    name = excluded.name, description = excluded.description, wilaya_id = excluded.wilaya_id,
    address = excluded.address, whatsapp_phone = excluded.whatsapp_phone,
    logo_url = coalesce(excluded.logo_url, stores.logo_url)
  returning id into sid;
  delete from store_delivery_wilayas where store_id = sid;
  insert into store_delivery_wilayas (store_id, wilaya_id)
    select sid, w from unnest(coalesce(p_delivery, '{}')) as w;
  return sid;
end $$;

create or replace function save_product(
  p_id uuid, p_store uuid, p_cat int, p_name text, p_desc text,
  p_price numeric, p_upc int, p_min int, p_stock int, p_images text[]
) returns uuid language plpgsql set search_path = public as $$
declare pid uuid; base int;
begin
  if p_id is null then
    insert into products (store_id, category_id, name, description, carton_price,
                          units_per_carton, min_qty_cartons, stock_cartons)
    values (p_store, p_cat, p_name, p_desc, p_price, p_upc, p_min, p_stock)
    returning id into pid;
  else
    update products set category_id = p_cat, name = p_name, description = p_desc,
           carton_price = p_price, units_per_carton = p_upc,
           min_qty_cartons = p_min, stock_cartons = p_stock
     where id = p_id returning id into pid;
    if pid is null then raise exception 'Product not found'; end if;
  end if;
  select coalesce(max(sort) + 1, 0) into base from product_images where product_id = pid;
  insert into product_images (product_id, url, sort)
    select pid, u, base + ord - 1 from unnest(coalesce(p_images, '{}')) with ordinality as t(u, ord);
  return pid;
end $$;

revoke execute on function save_store(text, text, smallint, text, text, text, smallint[]) from public, anon;
revoke execute on function save_product(uuid, uuid, int, text, text, numeric, int, int, int, text[]) from public, anon;
grant  execute on function save_store(text, text, smallint, text, text, text, smallint[]) to authenticated;
grant  execute on function save_product(uuid, uuid, int, text, text, numeric, int, int, int, text[]) to authenticated;


-- ============================================================
-- v1.2 — بحث عربي موحّد + إحصائيات المورد  (آمن لإعادة التشغيل)
-- ============================================================
create or replace function norm_ar(t text) returns text language sql immutable as $$
  select translate(regexp_replace(lower(coalesce(t,'')), '[\u064B-\u0652\u0640]', '', 'g'), 'أإآةىؤئ', 'اااهيوي') $$;
create index if not exists products_name_norm on products using gin (norm_ar(name) gin_trgm_ops);

create or replace function search_products(
  q text default null, delivers_to smallint default null, cat_id int default null,
  max_price numeric default null, lim int default 24, off int default 0
) returns setof products_public
language sql stable set search_path = public as $$
  select * from products_public pp
  where (q is null or q = '' or norm_ar(pp.name) like '%' || norm_ar(left(q, 60)) || '%'
         or norm_ar(pp.store_name) like '%' || norm_ar(left(q, 60)) || '%')
    and (cat_id is null or pp.category_id = cat_id
         or pp.category_id in (select id from categories where parent_id = cat_id))
    and (max_price is null or pp.carton_price <= max_price)
    and (delivers_to is null or exists (
          select 1 from store_delivery_wilayas d
          where d.store_id = pp.store_id and d.wilaya_id = delivers_to))
  order by pp.created_at desc
  limit least(greatest(coalesce(lim, 24), 1), 48)
  offset greatest(coalesce(off, 0), 0);
$$;

create or replace function my_stats()
returns table(product_id uuid, name text, clicks7 bigint, clicks30 bigint)
language sql stable set search_path = public as $$
  select p.id, p.name,
         count(c.id) filter (where c.created_at > now() - interval '7 days'),
         count(c.id) filter (where c.created_at > now() - interval '30 days')
  from products p
  join stores s on s.id = p.store_id and s.owner_id = auth.uid()
  left join whatsapp_clicks c on c.product_id = p.id and c.created_at > now() - interval '30 days'
  group by p.id, p.name order by 4 desc, p.name;
$$;

create or replace function my_stats_wilaya()
returns table(wilaya_id smallint, clicks bigint)
language sql stable set search_path = public as $$
  select c.wilaya_id, count(*)
  from whatsapp_clicks c
  join stores s on s.id = c.store_id and s.owner_id = auth.uid()
  where c.wilaya_id is not null and c.created_at > now() - interval '30 days'
  group by c.wilaya_id order by 2 desc limit 10;
$$;

revoke execute on function my_stats(), my_stats_wilaya() from public, anon;
grant  execute on function my_stats(), my_stats_wilaya() to authenticated;


-- ============================================================
-- v1.3 — ترتيب النتائج (الأحدث / الأرخص / الأغلى)
-- ============================================================
drop function if exists search_products(text, smallint, int, numeric, int, int);
create or replace function search_products(
  q text default null, delivers_to smallint default null, cat_id int default null,
  max_price numeric default null, lim int default 24, off int default 0, sort_by text default 'new'
) returns setof products_public
language sql stable set search_path = public as $$
  select * from products_public pp
  where (q is null or q = '' or norm_ar(pp.name) like '%' || norm_ar(left(q, 60)) || '%'
         or norm_ar(pp.store_name) like '%' || norm_ar(left(q, 60)) || '%')
    and (cat_id is null or pp.category_id = cat_id
         or pp.category_id in (select id from categories where parent_id = cat_id))
    and (max_price is null or pp.carton_price <= max_price)
    and (delivers_to is null or exists (
          select 1 from store_delivery_wilayas d
          where d.store_id = pp.store_id and d.wilaya_id = delivers_to))
  order by case when sort_by = 'cheap' then pp.carton_price end asc,
           case when sort_by = 'exp'   then pp.carton_price end desc,
           pp.created_at desc
  limit least(greatest(coalesce(lim, 24), 1), 48)
  offset greatest(coalesce(off, 0), 0);
$$;


-- ============================================================
-- v1.4 — شارة التوثيق + استيراد المنتجات بالجملة
-- ============================================================
alter table stores add column if not exists verified boolean not null default false;

create or replace function protect_store_verified() returns trigger
language plpgsql set search_path = public as $$
begin
  if auth.uid() is not null and not is_admin() then
    if tg_op = 'INSERT' then new.verified := false;
    elsif new.verified is distinct from old.verified then raise exception 'Only admins can verify'; end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_protect_verified on stores;
create trigger trg_protect_verified before insert or update on stores
  for each row execute function protect_store_verified();

create or replace view stores_public with (security_invoker = false) as
select s.id, s.name, s.description, s.logo_url, s.wilaya_id, s.address, s.whatsapp_phone, s.created_at, s.verified
from stores s
where s.status = 'approved' and not is_blocked_user(s.owner_id);
grant select on stores_public to anon, authenticated;

create or replace function import_products(p_store uuid, p_rows jsonb) returns int
language plpgsql set search_path = public as $$
declare r jsonb; n int := 0; cid int;
begin
  if jsonb_array_length(p_rows) > 300 then raise exception 'الحد الأقصى 300 صف'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    select id into cid from categories where name_ar = trim(r->>'category') limit 1;
    insert into products (store_id, category_id, name, description, carton_price,
                          units_per_carton, min_qty_cartons, stock_cartons)
    values (p_store, coalesce(cid, (select id from categories order by sort limit 1)),
            trim(r->>'name'), r->>'description', (r->>'carton_price')::numeric,
            greatest(coalesce((r->>'units_per_carton')::int, 1), 1),
            greatest(coalesce((r->>'min_qty')::int, 1), 1),
            greatest(coalesce((r->>'stock')::int, 0), 0));
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function import_products(uuid, jsonb) from public, anon;
grant  execute on function import_products(uuid, jsonb) to authenticated;


-- ============================================================
-- v1.5 — تاريخ السعر، وضع الإجازة، تقييمات، بلاغات، طلبات عروض الأسعار
-- ============================================================
alter table stores   add column if not exists is_paused boolean not null default false;
alter table products add column if not exists price_updated_at timestamptz not null default now();

create or replace function touch_price() returns trigger language plpgsql as $$
begin
  if new.carton_price is distinct from old.carton_price then new.price_updated_at := now(); end if;
  return new;
end $$;
drop trigger if exists trg_touch_price on products;
create trigger trg_touch_price before update on products for each row execute function touch_price();

drop function if exists search_products(text, smallint, int, numeric, int, int, text);
create or replace view products_public with (security_invoker = false) as
select p.id, p.name, p.description, p.carton_price, p.unit_price, p.units_per_carton,
       p.min_qty_cartons, p.stock_cartons, p.category_id, p.created_at,
       s.id as store_id, s.name as store_name, s.logo_url, s.wilaya_id as store_wilaya_id,
       s.whatsapp_phone,
       (select url from product_images i where i.product_id = p.id order by sort limit 1) as image_url,
       p.price_updated_at
from products p join stores s on s.id = p.store_id
where p.is_active and not p.is_hidden_by_admin and s.status = 'approved'
  and not s.is_paused and not is_blocked_user(s.owner_id);
grant select on products_public to anon, authenticated;

create or replace view stores_public with (security_invoker = false) as
select s.id, s.name, s.description, s.logo_url, s.wilaya_id, s.address, s.whatsapp_phone, s.created_at, s.verified
from stores s
where s.status = 'approved' and not s.is_paused and not is_blocked_user(s.owner_id);
grant select on stores_public to anon, authenticated;

create or replace function search_products(
  q text default null, delivers_to smallint default null, cat_id int default null,
  max_price numeric default null, lim int default 24, off int default 0, sort_by text default 'new'
) returns setof products_public
language sql stable set search_path = public as $$
  select * from products_public pp
  where (q is null or q = '' or norm_ar(pp.name) like '%' || norm_ar(left(q, 60)) || '%'
         or norm_ar(pp.store_name) like '%' || norm_ar(left(q, 60)) || '%')
    and (cat_id is null or pp.category_id = cat_id
         or pp.category_id in (select id from categories where parent_id = cat_id))
    and (max_price is null or pp.carton_price <= max_price)
    and (delivers_to is null or exists (
          select 1 from store_delivery_wilayas d
          where d.store_id = pp.store_id and d.wilaya_id = delivers_to))
  order by case when sort_by = 'cheap' then pp.carton_price end asc,
           case when sort_by = 'exp'   then pp.carton_price end desc,
           pp.created_at desc
  limit least(greatest(coalesce(lim, 24), 1), 48)
  offset greatest(coalesce(off, 0), 0);
$$;

-- تقييمات الموردين (أصحاب المحلات فقط، تقييم واحد لكل متجر)
create table if not exists reviews (
  store_id uuid not null references stores(id) on delete cascade,
  user_id  uuid not null references profiles(id) on delete cascade,
  rating   smallint not null check (rating between 1 and 5),
  comment  text check (char_length(comment) <= 300),
  author   text,
  created_at timestamptz not null default now(),
  primary key (store_id, user_id)
);
alter table reviews enable row level security;
drop policy if exists "reviews read" on reviews;
create policy "reviews read" on reviews for select using (true);
drop policy if exists "reviews admin" on reviews;
create policy "reviews admin" on reviews for all using (is_admin()) with check (is_admin());
create or replace view store_ratings with (security_invoker = false) as
  select store_id, avg(rating)::numeric(3,2) as avg, count(*) as cnt from reviews group by store_id;
grant select on store_ratings to anon, authenticated;

create or replace function save_review(p_store uuid, p_rating int, p_comment text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or is_blocked_user(auth.uid()) or not email_confirmed() then
    raise exception 'سجّل الدخول وأكّد بريدك أولاً'; end if;
  if not exists (select 1 from profiles where id = auth.uid() and role = 'shop_owner') then
    raise exception 'التقييم لأصحاب المحلات فقط'; end if;
  if not exists (select 1 from stores_public where id = p_store) then raise exception 'المتجر غير موجود'; end if;
  insert into reviews (store_id, user_id, rating, comment, author)
  values (p_store, auth.uid(), least(greatest(p_rating, 1), 5), left(p_comment, 300),
          (select split_part(full_name, ' ', 1) from profiles where id = auth.uid()))
  on conflict (store_id, user_id) do update
    set rating = excluded.rating, comment = excluded.comment, created_at = now();
end $$;
revoke execute on function save_review(uuid, int, text) from public, anon;
grant  execute on function save_review(uuid, int, text) to authenticated;

-- بلاغات المستخدمين
create table if not exists reports (
  id bigint generated always as identity primary key,
  product_id uuid references products(id) on delete cascade,
  store_id   uuid references stores(id) on delete cascade,
  user_id    uuid references profiles(id) on delete set null,
  reason     text not null check (char_length(reason) between 3 and 300),
  created_at timestamptz not null default now()
);
alter table reports enable row level security;
drop policy if exists "reports insert" on reports;
create policy "reports insert" on reports for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "reports admin" on reports;
create policy "reports admin" on reports for all using (is_admin()) with check (is_admin());

-- طلبات عروض الأسعار (صاحب المحل ينشر، الموردون يرون ويتواصلون)
create table if not exists rfq (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  wilaya_id smallint not null references wilayas(id),
  item  text not null check (char_length(item) between 3 and 200),
  qty   text check (char_length(qty) <= 60),
  phone text not null check (phone ~ '^213[567][0-9]{8}$'),
  created_at timestamptz not null default now()
);
create index if not exists rfq_created on rfq (created_at desc);
alter table rfq enable row level security;
drop policy if exists "rfq read" on rfq;
create policy "rfq read" on rfq for select using (user_id = auth.uid() or is_active_supplier() or is_admin());
drop policy if exists "rfq insert" on rfq;
create policy "rfq insert" on rfq for insert with check (
  user_id = auth.uid() and email_confirmed()
  and exists (select 1 from profiles where id = auth.uid() and role = 'shop_owner' and not is_blocked)
  and (select count(*) from rfq r where r.user_id = auth.uid() and r.created_at > now() - interval '1 day') < 5);
drop policy if exists "rfq delete" on rfq;
create policy "rfq delete" on rfq for delete using (user_id = auth.uid() or is_admin());


-- ============================================================
-- v1.6 — روابط/ساعات/توصيل، رابط الدعوة، أسعار حسب الكمية، عروض بمدة
-- ============================================================
alter table stores
  add column if not exists facebook text check (facebook ~ '^https://(www\.)?(facebook|fb)\.com/'),
  add column if not exists instagram text check (instagram ~ '^https://(www\.)?instagram\.com/'),
  add column if not exists hours text check (char_length(hours) <= 100),
  add column if not exists delivery_fee int check (delivery_fee >= 0),
  add column if not exists delivery_days smallint check (delivery_days between 1 and 30),
  add column if not exists min_order int check (min_order >= 0);

create or replace view stores_public with (security_invoker = false) as
select s.id, s.name, s.description, s.logo_url, s.wilaya_id, s.address, s.whatsapp_phone, s.created_at, s.verified,
       s.facebook, s.instagram, s.hours, s.delivery_fee, s.delivery_days, s.min_order
from stores s
where s.status = 'approved' and not s.is_paused and not is_blocked_user(s.owner_id);
grant select on stores_public to anon, authenticated;

-- رابط الدعوة
alter table profiles add column if not exists referred_by uuid references profiles(id) on delete set null;
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare ref uuid;
begin
  if (new.raw_user_meta_data->>'ref') ~ '^[0-9a-f-]{36}$' then
    select id into ref from profiles where id = (new.raw_user_meta_data->>'ref')::uuid;
  end if;
  insert into profiles (id, full_name, phone, role, referred_by)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', ''), new.raw_user_meta_data->>'phone',
          case when new.raw_user_meta_data->>'role' = 'supplier' then 'supplier'::user_role else 'shop_owner'::user_role end,
          ref);
  return new;
end $$;
create or replace function my_invites() returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from profiles where referred_by = auth.uid();
$$;
revoke execute on function my_invites() from public, anon;
grant  execute on function my_invites() to authenticated;

-- أسعار حسب الكمية
create table if not exists product_tiers (
  product_id uuid not null references products(id) on delete cascade,
  min_qty int not null check (min_qty > 1),
  price numeric(12,2) not null check (price > 0),
  primary key (product_id, min_qty)
);
-- عروض بمدة محددة
create table if not exists promos (
  product_id uuid primary key references products(id) on delete cascade,
  price numeric(12,2) not null check (price > 0),
  until timestamptz not null
);
alter table product_tiers enable row level security;
alter table promos        enable row level security;
drop policy if exists "tiers read" on product_tiers;
create policy "tiers read" on product_tiers for select using (true);
drop policy if exists "tiers owner" on product_tiers;
create policy "tiers owner" on product_tiers for all
  using (is_active_supplier() and exists (select 1 from products p join stores s on s.id = p.store_id where p.id = product_id and s.owner_id = auth.uid()))
  with check (is_active_supplier() and exists (select 1 from products p join stores s on s.id = p.store_id where p.id = product_id and s.owner_id = auth.uid()));
drop policy if exists "promos read" on promos;
create policy "promos read" on promos for select using (true);
drop policy if exists "promos owner" on promos;
create policy "promos owner" on promos for all
  using (is_active_supplier() and exists (select 1 from products p join stores s on s.id = p.store_id where p.id = product_id and s.owner_id = auth.uid()))
  with check (is_active_supplier() and exists (select 1 from products p join stores s on s.id = p.store_id where p.id = product_id and s.owner_id = auth.uid()));
