# План перехода на собственный сервер

Цель: чтобы Let's Walk работал сам по себе, без Claude, с регистрацией пользователей и онлайн-обновлениями.

Рекомендуемый стек на старте: **Supabase** (база Postgres, вход, обновления в реальном времени, хранилище фото). На старте он бесплатный, а данные легко выгрузить. Firebase тоже подойдёт.

## 1. Данные

Таблицы повторяют то, что уже хранит прототип.

### `profiles`
| поле | тип | описание |
|---|---|---|
| id | uuid, = auth.users.id | пользователь |
| name | text | отображаемое имя |
| avatar_url | text | фото |
| created_at | timestamptz | |

### `walks`
| поле | тип | описание |
|---|---|---|
| id | uuid | |
| author_id | uuid → profiles | кто зовёт |
| place | text | место встречи |
| lat, lng | double, nullable | точка на карте (позже) |
| start_at | timestamptz | начало |
| duration_min | int | 30 / 45 / 60 / 90 |
| mood | text | настроение |
| note | text | заметка до 140 символов |
| route | jsonb | точки маршрута |
| visibility | text | `friends` или `public` |
| created_at | timestamptz | |

### `walk_participants`
| поле | тип | описание |
|---|---|---|
| walk_id | uuid → walks | |
| user_id | uuid → profiles | |
| joined_at | timestamptz | |
| PRIMARY KEY (walk_id, user_id) | | один человек — одна запись |

### `friendships` (позже)
| поле | тип |
|---|---|
| user_id, friend_id | uuid |
| status | `pending` / `accepted` |

## 2. Права доступа (Row Level Security)

- Читать прогулку может её автор, его друзья (`visibility = friends`) или все (`visibility = public`).
- Создавать прогулку можно только от своего имени (`author_id = auth.uid()`).
- Изменять и удалять прогулку может только автор.
- Присоединиться или выйти можно только за себя (`user_id = auth.uid()`).

## 3. Соответствие прототипу

| Прототип | Свой сервер |
|---|---|
| `db.collection("walks").onSnapshot(...)` | `supabase.channel(...).on('postgres_changes', { table: 'walks' })` + начальный `select` |
| `db.collection("walks").add(doc)` | `supabase.from('walks').insert(doc)` |
| `db.collection("joins").doc(id).set(...)` | `supabase.from('walk_participants').insert(...)` |
| `user.id()`, `user.profiles(ids)` | `supabase.auth.getUser()`, `select` из `profiles` |
| `room.onPeers(...)` (кто онлайн) | Supabase Realtime Presence |
| `sample.json(...)` (маршрут от AI) | серверная функция (Edge Function), которая вызывает API модели; ключ API хранится только на сервере |

## 4. Порядок работ

1. Создать проект Supabase, таблицы и правила доступа из разделов 1–2.
2. Вход по email или через Apple / Google.
3. Заменить в `prototype/index.html` вызовы `claude.use(...)` на Supabase и выложить веб-версию (Vercel, Netlify или GitHub Pages).
4. Edge Function для подсказки маршрута.
5. Карта и геолокация: точка встречи, «кто гуляет рядом».
6. Push-уведомления.
7. Мобильное приложение на Expo (React Native) с тем же сервером.

## 5. Безопасность до публичного запуска

- Жалобы на пользователей и прогулки, блокировка.
- Ограничение частоты создания прогулок (антиспам).
- Подтверждение номера телефона или email.
- Режим «только друзья» по умолчанию.
- Кнопка «поделиться маршрутом с близким».
- Политика конфиденциальности: точная геолокация не показывается незнакомым людям.
