create type food_category_t as enum ('Chinese', 'Western', 'Malay', 'Indian', 'Fast food');
create type payment_mode_t as enum ('Cash', 'Card');
create type shift_t AS ENUM ('1', '2', '3', '4', '0'); -- '0' means rest day.
create type rider_type_t AS ENUM ('full_time', 'part_time');

create type promo_rule_t as enum ('ORDER_TOTAL', 'NTH_ORDER', 'INACTIVITY');
create type promo_action_t as enum ('FOOD_DISCOUNT', 'DELIVERY_DISCOUNT');

/*
 General user information.
 User password are hashed before saving into database (see: tr_hash_password).
 */
create table Users
(
    id        varchar(20) primary key,
    password  text        not null,
    username  varchar(50) not null,
    join_date DATE        not null default CURRENT_TIMESTAMP
);


/* FDS manager accounts */
create table Managers
(
    id varchar(20) primary key references Users (id) on delete cascade
);

/* Restaurant staff accounts */
create table Restaurants
(
    id            varchar(20) primary key references Users (id) on delete cascade,
    rname         varchar(50),
    description   varchar(1000), -- brief information of the restaurant,
    minimum_spend money        not null default 0 check (minimum_spend > 0::money),
    address       varchar(100) not null,
    lon           float        not null check (fn_check_lon(lon)),
    lat           float        not null check (fn_check_lat(lat))
);

/* FDS customer accounts. */
create table Customers
(
    id            varchar(20) primary key references Users (id) on delete cascade,
    reward_points float not null default 0 check (reward_points >= 0)
);

/* FDS rider accounts */
create table Riders
(
    id   varchar(20) primary key references Users (id) on delete cascade,
    type rider_type_t not null,
    lon  float check (fn_check_lon(lon)),
    lat  float check (fn_check_lat(lat))
);

/* Food items each restaurant is selling. */
create table Sells
(
    rid              varchar(20) references Restaurants (id) on delete cascade,
    food_name        varchar(50) check (not food_name = ''),
    food_description text,
    food_category    food_category_t not null,
    daily_limit      integer         not null,
    daily_sold       integer         not null default 0,
    price            money           not null check (price >= 0::money),

    constraint daily_limit check (daily_limit >= 0 and daily_limit >= daily_sold),
    constraint daily_sold check (daily_sold >= 0),
    primary key (rid, food_name)
);

/*
 Customers' delivery addresses.
 Guarantees: Each customer can have at most 5 locations (by tr_ensure_maximum_recent_location).
             Least recent used locations will be removed if the locations for a customer are full and new locations are added.
 */
create table CustomerLocations
(
    cid            varchar(20),
    lon            float check (fn_check_lon(lon)),
    lat            float check (fn_check_lat(lat)),
    address        varchar(100) not null,
    last_used_time timestamp    not null default CURRENT_TIMESTAMP,

    foreign key (cid) references Customers (id) on delete cascade,
    primary key (cid, lon, lat)
);

create table Orders
(
    id             serial,
    rid            varchar(20)    references Restaurants (id) on delete set null,
    delivery_cost  money          not null default 0::money check (delivery_cost >= 0::money),
    food_cost      money          not null default 0::money check (food_cost >= 0::money),

    -- delivery information
    rider_id       varchar(20)             default null references Riders (id), /* TODO: Assign rider to order based on rider schedule */
    cid            varchar(20),
    lon            float check (fn_check_lon(lon)),
    lat            float check (fn_check_lat(lat)),

    -- timing information
    time_placed    timestamp      not null default CURRENT_TIMESTAMP,
    time_depart    timestamp               default null,
    time_collect   timestamp               default null,
    time_leave     timestamp               default null,
    time_delivered timestamp               default null,
    time_paid      timestamp               default null,

    payment_mode   payment_mode_t not null,

    remarks        varchar(500)            default '',

    foreign key (cid, lon, lat) references CustomerLocations (cid, lon, lat) on delete set null,
    primary key (id)
);

create table Reviews
(
    oid         integer primary key not null references Orders (id) on delete cascade,
    rating      integer check (rating >= 1 and rating <= 5),
    content     varchar(1000)       not null,
    create_time timestamp           not null default CURRENT_TIMESTAMP
);

/*
 Food items of orders.
 Guarantees: All food items for a single order is from the same restaurant (by tr_order_food_from_same_restaurant).
 */
create table OrderFoods
(
    id        serial,
    oid       integer not null references Orders (id) on delete cascade,
    rid       varchar(20),
    food_name varchar(50),
    quantity  integer not null check (quantity > 0),

    foreign key (rid, food_name) references Sells (rid, food_name) on delete set null,
    unique (oid, rid, food_name),
    primary key (id) -- cannot use aggregate key (oid, rid, food_name) because rid should be set to null when an item is deleted by restaurant

);

create table Registers
(
    cid         varchar(20) references Customers (id),
    card_number varchar(19) references Cards (number),
    primary key (cid, card_number),
    unique (cid)
);

create table Cards
(
    number varchar(19) not null check (number ~ $$\d{4}-?\d{4}-?\d{4}-?\d{4}$$),             -- 16 digits (optionally separated by hyphens)
    expiry varchar(7)  not null check (expiry ~ $$^(0[1-9]|1[0-2])\/?([0-9]{4}|[0-9]{2})$$), -- valid formats: MM/YY, MMYY, MM/YYYY, MM/YY
    name   varchar(20) not null,
    cvv    varchar(4)  not null check (cvv ~ $$^[0-9]{3,4}$$),                               -- 3 or 4 digits
    primary key (number)
);

create table PromotionRules
(
    id       serial primary key,

    giver_id varchar(20) not null references Users (id) on delete cascade check (fn_check_promotion_giver_domain(giver_id)),

    rtype    promo_rule_t,
    config   jsonb
);

create table PromotionActions
(
    id       serial primary key,

    giver_id varchar(20) not null references Users (id) on delete cascade check (fn_check_promotion_giver_domain(giver_id)),

    atype    promo_action_t,
    config   jsonb
);

create table Promotions
(
    id         serial primary key,

    promo_name varchar(50)       not null,
    rule_id    integer           not null references PromotionRules (id) on delete cascade,
    action_id  integer           not null references PromotionActions (id) on delete cascade,

    num_orders integer default 0 not null,

    start_time timestamp         not null,
    end_time   timestamp         not null check (start_time <= end_time),

    giver_id   varchar(20)       not null references Users (id) on delete cascade check (fn_check_promotion_giver_domain(giver_id))
);

/*
  Full time riders work schedule
  - Guarantees: Differences among each start_date are at least 1 month.
 */
create table FWS
(
    rid        varchar(20) references Riders (id) on delete cascade,
    start_date date,
    day_one    shift_t not null default '0',
    day_two    shift_t not null default '0',
    day_three  shift_t not null default '0',
    day_four   shift_t not null default '0',
    day_five   shift_t not null default '0',
    day_six    shift_t not null default '0',
    day_seven  shift_t not null default '0',

    constraint c1 check (fn_get_rider_type(rid) = 'full_time'),
    constraint c2 check (fn_check_start_date()),
    constraint c3 check (fn_check_shifts(array [day_one, day_two, day_three, day_four, day_five, day_six, day_seven])),
    primary key (rid, start_date)
);

create table Shifts
(
    shift_num         shift_t primary key,
    first_start_hour  integer check (first_start_hour >= 10 and first_start_hour < 22),
    first_end_hour    integer check (first_end_hour > 10 and first_end_hour <= 22),
    second_start_hour integer check (second_start_hour >= 10 and second_start_hour < 22),
    second_end_hour   integer check (second_end_hour > 10 and second_end_hour <= 22)
);

/*
  Ensures time intervals of each day in PWS do not overlap.
 */
create or replace function fn_check_time_overlap() returns boolean as
$$
begin
    return not exists(select 1
                      from PWS P1
                               join PWS P2 using (rid, start_of_week, day_of_week)
                      where P1.start_hour <> P2.start_hour
                        and (P1.end_hour >= P2.start_hour and P1.end_hour <= P2.end_hour));
end;
$$ language plpgsql;

/*
  Part time workers work schedule
 */
create table PWS
(
    rid           varchar(20) references Riders (id) on delete cascade,
    start_of_week date    not null,
    day_of_week   integer check (day_of_week in (0, 1, 2, 3, 4, 5, 6)),
    start_hour    integer not null check (start_hour >= 10 and start_hour <= 21),
    end_hour      integer not null check (end_hour >= 11 and end_hour <= 22),

    check (fn_get_rider_type(rid) = 'part_time'),
    check (end_hour - start_hour <= 4 and end_hour > start_hour),
    check (fn_check_time_overlap()),
    check (fn_check_start_of_week()),
    primary key (rid, start_of_week, day_of_week, start_hour)
);

/*
  Each tuples represent salaries that week/month.
 */
create table Salaries
(
    rid        varchar(20) references Riders (id) on delete cascade,
    start_date date,
    base       money not null,
    bonus      money not null default 0,

    check (fn_check_salary_date(rid, start_date)),
    -- update bonus once an order is completed. trigger

    primary key (rid, start_date)
);
