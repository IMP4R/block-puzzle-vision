# blockbot — разбор текущего состояния кода

Проект: `/home/user/kimirmes/projects/watermark-research/blockbot_5743_retrained`
Режим: только чтение (файлы, логи, git). Ничего не запускалось и не собиралось.
Дата разбора: по состоянию файловой системы на момент чтения.

---

## 0. Краткий вывод

Это **не играющий бот в продуктивном смысле**. Реализован и доказанно работает
только один участок: *захват окна iPhone Mirroring → распознавание поля 8×8 и трёх
фигур в лотке → точное решение на полный лоток → отправка drag через CGEvent*.
Цикл «игра сыграна → проигрыш → закрыть рекламу → забрать монеты → новая игра»
**не реализован ни в одной из трёх Swift-версий**. Есть только частичный каркас
перезапуска (`batchRestartGame`), который слепо жмёт «Назад» и трижды «Да» и не
умеет ни определить проигрыш, ни закрыть рекламное окно, ни забрать награду.

Максимальный фактически достигнутый результат в логах — `BATCH DONE verified=30`
(30 ходов, ~10 раундов, одна сессия), при цели сбора 200–201.

---

## 1. Карта файлов проекта

Каталог: `blockbot_5743_retrained`, 8.1 MB, git-репозиторий — **общий родительский**
(`watermark-research`), не проектный; последний коммит `504b6c0 relay: upstream proxy
configurable via env` относится к notion-пайплайну, а не к blockbot. **Истории
разработки blockbot в git нет** — версионирование ведётся копиями файлов с суффиксом
`.before_<причина>_<YYYYMMDD_HHMM>`.

### Главные файлы

| Файл | Размер | Строк | Роль |
|---|---|---|---|
| `blockbot_strict_combined.5743_retrained.swift` | 139 809 B | 2788 | **основной бот**, «retrained»-ветка (production batch) |
| `blockbot_strict_combined.5743_lure_collector.swift` | 143 467 B | 2858 | тот же бот + режим сбора «приманок» (`--collect-target`) |
| `blockbot_strict_combined.5743_collector.swift` | 140 129 B | 2791 | промежуточная сборщик-версия |
| `blockbot_lure_solver.cpp` | 45 900 B | ~340 | **внешний C++ решатель** (`--solve-lure`, `--solve-steering`, `--million-bench`) |
| `blockbot_steering_solver.5722.cpp` | 37 105 B | — | предыдущая ревизия steering-решателя |
| `blockbot_strict_bin.5743_retrained` | 443 392 B | — | скомпилированный бинарник (Mach-O) |
| `blockbot_strict_bin.5743_lure_collector` | 443 720 B | — | бинарник коллектора |
| `blockbot_lure_solver_bin` | 255 416 B | — | бинарник C++ решателя |
| `blockbot_steering_solver_bin` | 218 848 B | — | бинарник steering-решателя |
| `blockbot_empirical_trays_merged.seed.tsv` | 39 203 B | — | эмпирическая модель лотков (реальные частоты) |
| `runtime/blockbot_calibration/strict.jsonl` | 473 383 B | 2262 | **журнал наблюдений** (board/pieces/plan/результат) |
| `runtime/blockbot_transfer_cache_v4.json` | 9 209 B | — | выученные профили переноса фигур |
| `active_collection_model.py` | — | 119 | ранжирование «невиданных» фигур как целей сбора |
| `seed_model.json` | — | — | список гипотез-фигур и наблюдённые частоты |

### Скрипты прогонов

| Файл | Строк | Назначение |
|---|---|---|
| `run_strict_exposure_collection.sh` | 57 | сбор 200 «строгих» экспозиций (эпохи 30001+) |
| `run_strict_exposure_collection_live_window.sh` | 52 | то же, но без касания restart-UI (поле уже видно) |
| `run_lure_collection_to_201.sh` | 46 | сбор приманок до 201 (стартует с базы 148, эпохи 1001+) |
| `run_exclusive_lure_200.sh` | 46 | эксклюзивные приманки |
| `run_collection_200.sh` | 36 | стартовый сбор |
| `resume_collection_to_201.sh` | 47 | возобновление |

### Бэкапы-«поколения» (не код для запуска, но важная история)

`*.swift.before_empirical_weights_20260814_2149`, `.before_pixel_diag_20260814_2138`,
`.before_failfast_20260814_2130`, `.before_dense_fix_20260814_2129`;
`blockbot_lure_solver.cpp.before_chain_threshold995_20260814_2215`,
`.before_chain_priority_20260814_2210`, `.before_1000move_bench_20260814_2206`,
`.before_exact_templates.cpp`, `.before_diverse_templates.cpp`,
`blockbot_lure_solver.template_experiments.discarded.cpp`;
`blockbot_steering_solver.5722.cpp`.

### Логи и данные прогонов

`collection_runs/<timestamp>_<mode>/` — 8 сессий с `session.txt`,
`model_epoch_*.json`, `run_epoch_*_attempt_*.log`, `final_status.json`,
`observed_shapes.tsv`. Плюс ~40 одиночных `.log` в корне (`build_*.log`,
`solver_test*.log`, `final_combo_*.log`, `steering_smoke.log`).

`runtime/` — PNG-кадры диагностики (`live_bot_capture.png`,
`restart_stuck_20260814-2105.png`, `iphone_home_hid_20260814-2113.png`,
`failed_initial_now.png`, `live_mirroring_w1971.png`) и логи зондов
(`bounded_vision_probe_*.log`, `bounded_pixel_diag.log`).

**README/документации нет** — `find . -name '*.md'` пусто (кроме созданного этим отчётом).

---

## 2. Архитектура

Весь конвейер — один файл `blockbot_strict_combined.5743_retrained.swift`.
Библиотек CV нет: **чистая попиксельная арифметика на сыром RGBA-буфере**, без
Core Image, Vision, OpenCV.

### 2.1 Захват окна iPhone Mirroring

- `OWNER` (стр. 4) — имя окна, обфусцировано юникод-эскейпами:
  `"\u{0412}...\u{0438}\u{0434}\u{0435}\u{043E}\u{043F}\u{043E}\u{0432}\u{0442}\u{043E}\u{0440} iPhone"` = «Видеоповтор iPhone».
- `findWin()` (стр. 51–61) — перебор `CGWindowListCopyWindowInfo(.optionAll)`,
  фильтр владельца + геометрия `height > 600 && width < 400` (вертикальное окно телефона).
- `findStrictWin()` (стр. 1218–1234) — то же, но `.optionOnScreenOnly`.
- `onscreen()` (стр. 62–67) — проверка, что окно в списке видимых.
- `grab()` (стр. 104–117) — **двухступенчатый захват**:
  1. `screencapture -x -o -l<windowID>` — читает backing store окна;
     иммунен к Night Shift/True Tone (комментарий стр. 106–110).
  2. если кадр мёртв (`deadFrame()` — >92 % чёрных пикселей в центральной
     области, стр. 87–103) — фолбэк на `screencapture -x -R x,y,w,h` (снимок области экрана).
- `captureTo()` (стр. 79–86) — запуск `/usr/sbin/screencapture` как `Process`.
- `decodeImg()` (стр. 68–78) — `NSImage` → `CGContext` RGBA → `[UInt8]`;
  вычисляет `scale = px_width / window_width_pt` (Retina).
- `focusStrictWindow()` (стр. 1235–1250) — `app.activate(.activateAllWindows)`,
  до 30 попыток по 10 мс добиться, чтобы приложение стало frontmost и границы совпали.
- `prepareStrictWindow()` (стр. 1251–1266) — ждёт стабилизации окна (6 одинаковых
  подряд измерений id+границ, до 80 итераций по 100 мс).

**Пороги**: `deadFrame` — `RGB < 24` каждый канал, > 92 % таких пикселей;
`findWin` — `height>600`, `width<400`.

### 2.2 Распознавание поля 8×8

- `EMPTY` (стр. 33) — эталон пустой клетки `(75, 75, 163)`; `EMPTY_REF` — рабочий
  эталон, уточняется medoid-ом.
- `boardState()` (стр. 124–161) — для каждой из 64 клеток берётся пиксель в центре
  (`BOARD.minX + (c+0.5)*cell`). Кандидаты «пусто» фильтруются по **квадрату
  расстояния < 3600 к `EMPTY_REF`**, затем medoid (минимум суммы квадратов
  расстояний внутри кандидатов) уточняет эталон. Клетка занята, если
  `dr²+dg²+db² > 324`. `LAST_EMPTY_SUPPORT` — число подтверждённых пустых.
  Комментарий стр. 133–136: специально ушли от кластеризации по большинству —
  на заполненном поле цвет блока мог стать доминирующим и инвертировать занятость.
- `boardBgColor()` (стр. 339–354) — гистограмма цветов области `x∈[16,300]`,
  `y∈[150,500]` с квантованием `/22` по каналам; самый частый цвет при `max>35` —
  фон поля. Дефолт `(68,77,147)`.
- `locateBoard()` (стр. 355–428) — **поиск поля по содержимому, а не по смещениям**:
  маска пикселей с `rgbDistance(bg) < 40` в окне `316×550` (y от 100 до 650),
  затем BFS-поиск наибольшей связной компоненты с критериями
  `w≥180, h≥180, |w-h| ≤ max(40, max(w,h)/5), плотность ≥ 0.40`. Комментарий
  стр. 358–360: заменяет прежнюю гистограмму строк/столбцов, которая «сжимала»
  панель при разрыве пробега занятыми строками.
- `boardGridScore()` (стр. 259–274) — оценка пригодности сетки: среднее
  `rgbDistance(центр, сосед слева/сверху)` + `0.35 ×` число «правдоподобных» клеток
  (`d<55` до фона или `mx>145 && mx-mn>35`).
- `boardCellGood()` / `cellGoodCount()` / `gridlineDips()` (стр. 285–332) — валидация
  клетки (равномерность: max попарное расстояние < 45; насыщенность `sat ≥ 0.45`)
  и подгонка сетки по «провалам» на линиях сетки.
- `adaptGeometry()` (стр. 430–452) — **блокировка сетки** (`LOCKED_GRID`): после
  двух совпадающих детекций и наличия 1–3 фигур сетка фиксируется; переиспользуется
  каждый цикл (защита от дрожания во время анимаций). Разблокировка — после 15
  подряд неудач (`LOCK_FAILS`). Печатает `GEO grid=(x,y,w) tray=<n> pend=<n>`.
- `applyAdaptiveGeometry()` (стр. 28–32) — пересчёт `BOARD`, `BAND`, `HINT_TOP`.
- `hasFullLine()` (стр. 1686–1690) — детектор кадра анимации очистки линии.

**Геометрия по умолчанию**: `BOARD = CGRect(x:39, y:194, width:237, height:237)` (стр. 10).
`SAVED_SHIFT = 0.0` (стр. 8) с комментарием: старый кэш сдвига содержал 65 pt от
плохой калибровки и уводил выборку в лоток (стр. 6–7).

**Пороги лотка** (доли высоты поля, стр. 16–19): `TRAY_BAND_START_RATIO=2/264`,
`TRAY_PIECE_MIN_TOP_RATIO=12/264`, `TRAY_CUTOFF_RATIO=0.41`,
`TRAY_EDGE_MARGIN_RATIO=1/264`. Комментарий стр. 11–15: нормальные фигуры
заканчиваются около 33.7 % ниже поля, графика подсказок начинается около 42.8 %,
отсечка 41 % оставляет запас с обеих сторон.

### 2.3 Распознавание фигур

- `detectPieces()` (стр. 180–257):
  1. `satAt()` (стр. 162–169) — пиксель «фигуры»: вне `3600` от `EMPTY_REF`,
     `mx > 120 && mx-mn > 70`.
  2. маска в полосе `BAND` (y0..y1).
  3. дилатация радиусом `R=5` — соединяет клетки одной фигуры через тонкие
     промежутки сетки (стр. 183–186).
  4. **2D связные компоненты** через DSU (union-find, `find`/`uni`, стр. 196–202) —
     заменили прежнюю группировку только по столбцам, которая склеивала
     перекрывающиеся по x фигуры в одну плохую.
  5. слияние пересекающихся bbox (зазор 8 px, стр. 208–227).
  6. фильтр `area ≥ 150` px, откат дилатации (`+R`/`-R`).
  7. нарезка на сетку: `pitch0 = 14.0 * (BOARD.width/237) * scale`
     (`rows`/`cols` через `round`), `pieceCellAt()` (стр. 170–179) с усреднением 3×3,
     порог `mx > 190 && mx-mn > 50`.
  8. тримминг пустых краёв, сборка `Piece(cells, rows, cols, ax, ay, bbox)`.
- `validTrayPieces()` (стр. 277–283) — фильтр: `connectedShape()`, верх фигуры ниже
  `BOARD.maxY + height*TRAY_PIECE_MIN_TOP_RATIO`, низ выше `HINT_TOP - margin`.
- `connectedShape()` (стр. 1126–1146) — проверка связности клеток фигуры.
- `strictShapeKey()` (стр. 1022–1024) — сериализация формы `"101/111"`.
- `trayStabilitySignature()` / `batchTraySignature()` — подпись лотка для
  подтверждения стабильности.

### 2.4 Решатель `bestMove`

Точка входа — `bestMove(board, ps, skips, streak)` (стр. 813–832):

1. **Сначала внешний C++ решатель** — `externalSteeringMove()` (стр. 780–812).
   Запускает `blockbot_steering_solver_bin` с `--solve-steering --board <bits>
   --pieces <keys|keys|keys> --streak N --skips N`, **таймаут 5.0 с**
   (стр. 789–791), парсит строку `OK ... seq=slot:r:c:clears;...`, и **перепроверяет
   всю последовательность локально** (`fits` + `dropP`, сверка заявленных очисток,
   стр. 798–809). При любом расхождении — откат к внутреннему решателю.
2. **Внутренний точный решатель** — `exactComboPlan()` (стр. 747–779):
   полный перебор всех перестановок всех 3 фигур по всем позициям с мемоизацией
   `ComboPlanKey(board, mask, streak, skips)`. Глубина — **вся тройка исчерпывающе**
   (`mask` из 3 бит), т.е. depth = 3 размещения, а не эвристическая.
   Функция ценности (стр. 751–754):
   ```
   score = streak * 1_000_000_000
         − (streak > 0 ? skips * 1_000_000 : 0)
         + evalB(board) + comboProbabilityPrep(board)
   ```
   То есть **комбо-серия доминирует над всем остальным** (1e9 за единицу streak),
   штраф за пропуски — только пока серия жива.
3. `completeTrayOptions()` (стр. 682–734) — альтернативный вариант планировщика
   с `CompleteOptions{noClear, withClear, withClearEarly}`, счётчиками
   `firstClearAt`/`trailingMisses` и тай-брейком `betterTail()` (стр. 669–681).
   В текущем `bestMove` не вызывается (используется в self-test).

**Эвристика `evalB()`** (стр. 473–503) — линейная комбинация:
```
+ empty        * 2.0     (свободные клетки)
− isolated     * 18.0    (клетка с ≤1 свободным соседом)
− transitions  * 1.8     (смены занятости по строкам/столбцам)
+ near         * 5.0     (строк/столбцов с ≥6 занятых)
+ almost       * 4.0     (ровно 7 из 8 — готовая линия под комбо)
+ fit3         * 5.0     (влезает квадрат 3×3)
+ fit23        * 1.8     (влезает 3×2)
+ fit5         * 3.0     (влезает полоса 5)
```

**Модель комбо** `COMBO_LINE_MODEL` (стр. 545–588) — предвычисленная таблица по
256 маскам дырок в линии, на основе 39 весов `COMBO_SHAPE_WEIGHTS` (стр. 504–544):
`rowCover`, `colCover`, `rowProgress`, `colProgress`. `comboProbabilityPrep()`
(стр. 589–611) суммирует по строкам и столбцам
`pow(filled/8, 3) × (160·cover + 25·progress)`.

**Правило комбо**: `COMBO_MAX_SKIPS = 2` (стр. 661) с комментарием «проверено:
третье подряд размещение без очистки рвёт цепочку; раунды лотков не важны».

**Стратегии C++ решателя** (`blockbot_lure_solver.cpp`):
- `struct Strategy` (стр. 99) с полями `legacy, prepBoard, horizon, discount,
  ratePenalty, futureScale, prepWeight, setupBoost, exactPlan, independentProb,
  terminalEvalWeight, terminalProxyWeight, streakProxyScale, comboMode, comboSkipWeight`.
- `futureValue()` (стр. 100) — дисконтированная выживаемость комбо по горизонту.
- `prep()` (стр. 98) — вероятностная модель подготовки поля (`pPiece`, `pTray`,
  `pIndependent`, `setup`, `expLines`) на основе полного каталога фигур и лотков.
- `ExactSolver::rec` (стр. 104+) — точный перебор с `horizon` (по умолчанию 7).
- `choosePlan()` (стр. 113) — выбор между `no/yes/early` с вычислением utility.
- `metrics()` (стр. 95) — очки: `linePoints = 10·lines`, `bonus = 10·streak`
  начиная со streak ≥ 2; `MAX_SKIPS = 2` (стр. 19).
- `--million-bench` — бенчмарк на миллион игр; `BASE_MOVE_SEC = 0.3640142857142857`
  и `CLEAR_DELAY_SEC = 0.450` (стр. 20–21) — калибровка времени хода.

### 2.5 Выполнение drag через CGEvent

Два разных пути.

**Медленный/точный `safeDrag()`** (стр. 956–996), используется в `runStrict`:
- Проверяет неизменность окна: `findStrictWin()` + `sameBounds()` до и после.
- Профили `robust ∈ {0,1,2}`: `downWait = [60, 90, 130] ms`,
  `dragSteps = [4, 7, 10]`, `settleWait = [90, 130, 180] ms` (стр. 966–968).
- Последовательность: `mouseMoved` → `leftMouseDown` → `leftMouseDragged` до
  середины → повторная проверка окна → `leftMouseDragged` до цели →
  `leftMouseUp` дважды (стр. 978–994). `defer` гарантирует отпускание.
- Прерывание: `controlledMove()` (стр. 938–947) и `activeWait()` (стр. 948–955)
  опрашивают `CONTROL.state().0` каждые ≤5 мс.

**Быстрый `batchUltraGesture()`** (стр. 2083–2107), production batch:
- Мгновенный прыжок курсора без интерполяции, затем
  `leftMouseDown` → ожидание `BATCH_DOWN_US` → **один** `leftMouseDragged` на цель →
  «нудж» `+1.0 px` и обратно (защита от коалесценции неподвижного drag в Mirroring,
  комментарий стр. 2099–2100) → `leftMouseUp` → `BATCH_GAP_US`.
- Тайминги (стр. 2019–2022): `BATCH_DOWN_US=20 000`, `BATCH_TARGET_US=10 000`,
  `BATCH_RELEASE_US=6 000`, `BATCH_GAP_US=4 000` мкс (переопределяются флагами).

**Точка переноса** — `batchTransferPoints(bounds, piece, row, col)` (стр. 2064–2082)
и `pickupPoint()` (стр. 868–881): берётся **ближайшая к центроиду занятая клетка**
фигуры (устойчивее к пустым краям). Целевая точка учитывает смещения
`TARGET_X_BIAS_BOARD_RATIO = 0.253/237`,
`TARGET_Y_LIFT_BOARD_RATIO = 88.780/237` (стр. 23–24) — нормированы на размер поля,
чтобы пережить перемещение/масштаб окна. `releaseInsideField()` (стр. 613–620)
отбрасывает варианты, где точка отпускания вышла бы за поле.

**Адаптивная коррекция**: `TransferProfile` (стр. 1035–1048) хранит на каждую форму
`pickupRow/Col`, `correctionXCells/YCells`, `exacts/resyncs/failures/exactStreak/uses`;
`trusted` — только после 5 подтверждённых попаданий подряд. Кэш —
`runtime/blockbot_transfer_cache_v4.json`, схема `adaptive-cells-v1`
(стр. 1026–1027, 1028–1034). `recordTransfer()` (стр. 1088+) обновляет статистику.

**Управление**: `BotControl` (стр. 882–905) — `NSLock`, флаги `running`/`quitting`,
удерживаемая точка `held`; `forceUp()` отпускает кнопку. Глобальный хоткей —
`installHotkeys()` / `hotkeyCallback()` (стр. 907–937), `CGEventTap` на
`cgSessionEventTap`, **Esc (keycode 53) = стоп**.

**Окно-подтверждение и drag-гард**: `safeDrag` и batch-цикл перепроверяют
`id` и `bounds` перед каждым жестом; при расхождении — `BATCH PAUSED window moved
before gesture batch` (стр. 2568) и пауза.

---

## 3. CLI-флаги и режимы

Точка входа (стр. 2788):
```swift
if ARGS.contains("--solver-test") { runSolverSelfTest() }
else if ARGS.contains("--legacy-strict") || ARGS.contains("--vision") || ARGS.contains("--probe") { runStrict() }
else { runBatchFast() }
```
**По умолчанию запускается `runBatchFast()`.**

### Режимы (взаимоисключающие)

| Флаг | Где | Поведение |
|---|---|---|
| `--solver-test` | 2788 | `runSolverSelfTest()` (стр. 2734–2787) — проверка решателя на фикстурах, `exit(2)` при провале |
| `--legacy-strict` / `--vision` / `--probe` | 2788 | вход в `runStrict()` (стр. 1691) |
| `--vision` | 1694, 1839–1849 | один цикл распознавания, печать `VISION ...`, затем стоп |
| `--probe` | 1693, 1911 | запрещает fast-путь даже для trusted-формы |
| `--batch-vision` | 2489–2493 | один захват, печать `BATCH VISION filled= grid= pieces=`, выход |
| `--restart-recover` | 2469–2478 | `batchRestartGame(..., skipBack=true, 0, nil)`, затем выход |
| `--restart-now` | 2494–2503 | `batchRestartGame(..., skipBack=false, ...)`, затем выход |
| `--sacrifice` | 1695, 1888–1893 | при неполном решении — `bestSingleMove()` (стр. 849–862), один ход в мёртвом лотке |
| `--once` | 44 | флаг объявлен, **в логике не используется** (только `let ONCE = ...`) |

### Параметры объёма

| Флаг | Дефолт | Строка |
|---|---|---|
| `--moves N` | batch: 30; strict: 50 | 2433, 1697 |
| `--rounds N` | `max(1,(moves+2)/3)` | 2435–2436 |
| `--duration-seconds N` | 0 (без лимита) | 2456 |
| `--max-attempts N` | `max(8, goal*5)` | 1698–1699 |
| `--max-error-restarts N` | 3 | 2521 |
| `--restart-every N` | 0, либо 35 при `--combo-timing-test` | 2443–2447 |

### Тайминги

| Флаг | Дефолт | Строка |
|---|---|---|
| `--fast-down-us` | 40 000 | 842 |
| `--fast-target-us` | 20 000 | 843 |
| `--fast-release-us` | 20 000 | 844 |
| `--batch-down-us` | 20 000 | 2019 |
| `--batch-target-us` | 10 000 | 2020 |
| `--batch-release-us` | 6 000 | 2021 |
| `--batch-gap-us` | 4 000 | 2022 |
| `--post-combo-ms` | 450 | 2453 |
| `--combo-delay-ms` | 50 | 2448 |
| `--combo-delay-step-ms` | 50 | 2449 |
| `--combo-delay-max-ms` | 1 500 | 2450–2451 |
| `--combo-timing-test` | off | 2442 |

Все *_us флаги проходят через `strictIntArg()` (стр. 837–841), который
**принудительно поднимает значение до минимум 1 000 мкс**.

### Состояние и кэш

| Флаг | Строка | Действие |
|---|---|---|
| `--reset-theory` | 1700, 2457 | `clearTheory()` — удаляет файл теорем |
| `--reset-cache` | 1701, 2458 | очистка `TRANSFER_CACHE` + `saveTransferCache()` |
| `--collect-target <shape>` | только в `*_lure_collector.swift`, стр. 44–48 | включает `COLLECT_LURE_MODE` |

### C++ решатель (`blockbot_lure_solver.cpp`, `main`, стр. 338)

| Флаг | Назначение |
|---|---|
| `--solve-lure` | `runLureSolve()` (стр. 305): `--board <bits> --pieces <k\|k\|k> --target <key>` |
| `--solve-steering` | `runSteeringSolve()` (стр. 318): `--board --pieces --streak --skips` — **вызывается из Swift** |
| `--million-bench` | бенчмарк: `--games --target --moves --seed --out` |
| `--graph-probe` | `--games --move-limit --seed --graph-out` |
| `--math-check-basic` | самопроверка |
| `--games --duration --move-limit --strat --seed` | прямой прогон симуляции |

---

## 4. Статус цикла «3 игры × (300 ходов → проигрыш → закрытие рекламы → сбор монет → новая игра)»

### 4.1 Что реально реализовано

**Есть** — покомандный batch-цикл `runBatchFast()` (стр. 2430–2732):

1. `captureBatchInitial()` (стр. 2246–2278) — стартовый захват с ожиданием
   стабильного поля и стабильного лотка (2 одинаковых подписи).
2. `--batch-vision` — вывод одного кадра.
3. Основной `while` (стр. 2554–2718): `bestMove` → план → `batchUltraGesture`
   на каждый ход → `captureNextTriple()` (стр. 2280–2353) как подтверждение
   (ждёт ровно 3 фигуры с дважды совпавшей подписью, отличной от старой).
4. `saveTheory()` / `loadTheory()` (стр. 1664–1680) — сохранение поля между
   запусками процесса.
5. `autoRestartAfterError()` (стр. 2522–2553) — перезапуск при ошибке с лимитом
   `--max-error-restarts`, пытается `preferSkipBack`, затем альтернативный режим.
6. `batchRestartGame()` (стр. 2187–2244) — **каркас перезапуска**:
   - `batchRestartTap()` по `BACK = CGPoint(x:28, y:85)` (стр. 36),
   - три тапа по `RESTART_YES = CGPoint(x:158, y:393)` (стр. 37),
     масштабируются как `bounds.width*(x/316)`, `bounds.height*(y/696)`
     (стр. 2195–2196),
   - `batchFreshFieldVisible()` (стр. 2127–2136) — проверка появления нового поля,
   - до 5 дополнительных тапов «Да», если поле не найдено,
   - `captureBatchRestartTray()` (стр. 2137–2186) — ожидание нового лотка.
7. `--restart-every N` — периодический перезапуск по счётчику ходов (стр. 2690–2711).
8. Статистика: `lines`, `maxCombo`, `linePoints`, `comboBonus`, `points`,
   `restarts`, `autoRestarts` (стр. 2721–2730).

### 4.2 Чего не хватает

**Не найдено в коде ни в одной из трёх Swift-версий:**

- **Детектор проигрыша.** Нет ни одной функции, распознающей game-over экран.
  Ближайшее — `captureNextTriple()` не находит 3 фигуры и возвращает `nil`, что
  даёт сообщение `BATCH ERROR next triple missing or game ended` (стр. 2661).
  Это **не распознавание проигрыша**, а таймаут ожидания лотка: тот же код
  сработает на рекламе, на анимации и на любом оверлее.
- **Сбор монет / наград.** Поиск по `coin|монет|reward|collectCoin` во всех
  `.swift`, `.py`, `.sh` — совпадения только на C++ переменную `reward` в
  функции ценности (`futureValue`, `ExactSolver`), это счёт очков, не монеты.
  **Функций сбора монет нет.**
- **Закрытие рекламы.** Нет OCR (`Vision`, `VNRecognizeText`, `osascript`,
  `cliclick`) — проверено grep'ом по всем `.swift`/`.sh`. Единственное упоминание —
  диагностические принты с задержкой в пустом лотке:
  `WAIT ad/overlay during tray transition` (стр. 1799) и `WAIT ad/overlay <idle>s`
  (стр. 1852) — бот **пассивно ждёт** и повторяет снимок, кнопку закрытия не ищет
  и не жмёт.
- **Новая игра после проигрыша.** `batchRestartGame` жмёт фиксированные
  «Назад» → «Да»×3 вслепую, без проверки, что на экране именно диалог рестарта.
  Имя `RESTART_YES` и комментарий стр. 2193 («OCR-калиброванный центр оранжевой
  кнопки "Да"») означают, что координаты получены OCR-ом **вручную при разработке**,
  а в рантайме OCR нет.
- **Цикл «3 игры».** Слов `3 games`, `games` как счётчик игр в Swift нет;
  `--games` встречается только в C++ симуляторе (`million-bench`, `graph-probe`),
  где это виртуальные игры без экрана. Скрипты коллекции задают
  `--moves`/`--rounds`, а не число игр.
- **300 ходов за игру.** Ни `300` как целевой счётчик ходов, ни `--moves 300`
  нигде не встречается. Максимум в скриптах — `--moves 30 --rounds 10`;
  `epoch=30001` в скриптах — это **номер эпохи модели сбора**, совпадение цифр,
  а не 300 ходов.

### 4.3 Что показывают логи

- Максимум по всем логам: `BATCH DONE verified=30` (несколько вхождений) —
  это 30 ходов ≈ 10 раундов, одна игровая сессия без рестарта.
- Последний прогон `run_6_5743_retrained_20260814-193901.log`:
  ~35 строк `BATCH WAIT initial field`, два `EXIT`, затем
  `BATCH AUTO RESTART initial capture failed` →
  `BATCH RESTART begin back=(28,85) yes=(158,393) skipBack=true` →
  `BATCH PAUSED restart yes tap 1 failed` →
  `BATCH DONE verified=0 attempted=0 rounds=0 autoRestartFailed=1`.
  Скрипт вернул `exit 0` (`run_6_5743_retrained_20260814-193901.exit`).
  **То есть цикл рестарта не отработал даже один раз.**
- Агрегат по логам: `BATCH PAUSED restart` ×21, `BATCH AUTO RESTART initial` ×9,
  `BATCH AUTO RESTART retry` ×6, `BATCH ERROR next` ×3, `BATCH PAUSED window` ×1.
  Доминируют падения на захвате/старте, а не на игре.
- `runtime/blockbot_calibration/strict.jsonl` (2262 строки) показывает, что
  **сбор данных шёл успешно**: последние записи — `round:70, verified:210,
  combo:103, lines:114`. Но это накопление между прогонами (через `--collect-target`
  и `saveTheory`), а не один 300-ходовой марафон: сессия прерывается, скрипт
  перезапускает бинарник.
- `collection_runs/20260814-203546_exclusive/`, `.../20260814-213942_strict_exposures/`
  содержат `final_status.json` и `observed_shapes.tsv` — сбор работал.

### 4.4 Итог по циклу

| Звено | Статус | Точное имя |
|---|---|---|
| Играть ходы | реализовано, работает | `runBatchFast`, `bestMove`, `batchUltraGesture` |
| Собрать поле/лоток | реализовано, работает | `boardState`, `validTrayPieces`, `captureBatchInitial` |
| Детект проигрыша | **не найдено** | — |
| Закрыть рекламу | **не найдено** | только пассивные принты `WAIT ad/overlay` (стр. 1799, 1852) |
| Собрать монеты | **не найдено** | — |
| Новая игра | частично (слепые тапы) | `batchRestartGame`, `batchRestartTap`, `batchFreshFieldVisible` |
| 3 игры × 300 ходов | **не найдено** | — |

---

## 5. Известные проблемы

### 5.1 Дрейф окна mirroring

- `sameBounds()` (стр. 864–867) — сравнение с допуском **< 1 pt** по всем четырём
  компонентам. Любое смещение окна на 1 pt делает окно «другим».
- Последствия — ранние выходы:
  - `safeDrag` стр. 959: `guard ... sameBounds(bounds, snapshot) else { return false }`
    — drag не отправляется вообще.
  - `safeDrag` стр. 983–989: если окно сдвинулось **в середине** drag, бот уводит
    курсор в `bounds.height - 35` и возвращает `false` — отмена жеста.
  - `captureAfter` стр. 1013, `captureBatchInitial` стр. 2250.
  - **`runBatchFast` стр. 2566–2569**: `BATCH PAUSED window moved before gesture batch`
    → `CONTROL.pause(); break` — весь прогон останавливается.
- В логах: `BATCH PAUSED window` ×1.
- `focusStrictWindow()` (стр. 1235–1250) требует совпадения границ внутри 30 попыток
  по 10 мс; `prepareStrictWindow()` (стр. 1251–1266) — 6 стабильных измерений из 80.
- Комментарий стр. 434–436: пере-детекция поля происходит только после 15
  подряд неудач (`LOCK_FAILS`), т.е. короткий дрейф гасится кэшем, а длинный —
  останавливает прогон.

### 5.2 `screencapture` vs `CGWindowListCreateImage`

- Реализован **только путь через `screencapture`** (`captureTo()`, стр. 79–86):
  внешний процесс `/usr/sbin/screencapture`, флаги `-x -o -l<id>` (по window id),
  фолбэк `-x -R<x,y,w,h>` (стр. 111–115).
- **`CGWindowListCreateImage` в коде не найдено.** `CGWindowListCopyWindowInfo`
  используется только для перечисления окон (стр. 52, 63, 1220), не для снятия изображения.
- Цена: каждый кадр — fork/exec процесса + запись PNG на диск (`/tmp/bb_cap.png`)
  + `NSImage`-декод. `decodeImg` (стр. 68–78) копирует весь буфер в `[UInt8]`
  (`Array(UnsafeBufferPointer(...))`, стр. 76) — полное копирование на каждый кадр.
- Обоснование в комментарии (стр. 106–110): window-id capture читает backing store
  и **иммунен к Night Shift / True Tone**, которые сдвигают цвета и ломают
  сопоставление по цвету. Это причина отказа от screen-level API, но не от
  `CGWindowListCreateImage` — тот тоже читает backing store и не требует процесса.
- Практический симптом: логи забиты `BATCH WAIT initial field` / `WAIT ad/overlay`
  — цикл ожидания переснимает экран каждые 20–1000 мс, каждый раз запуская процесс.

### 5.3 Почти полное поле / forced grid

- `boardState()` (стр. 133–140) — решено через привязку к `EMPTY_REF` + medoid
  вместо кластеризации по большинству. Комментарий явно описывает прежний баг:
  «когда поле занято, цвет блока может быть более частым и молча инвертировать
  занятость».
- Порог «пусто»: `d² < 3600` (расстояние < 60) для кандидатов, `d² > 324`
  (расстояние > 18) для занятой клетки — **зазор между 18 и 60** оставляет
  серую зону неопределённости, которая при почти полном поле попадает в «занято».
- `LAST_EMPTY_SUPPORT` (стр. 141) — если 0, поле считается нераспознанным;
  `captureBatchInitial` стр. 2261 требует `LAST_EMPTY_SUPPORT > 0`.
- `locateBoard()` (стр. 396): критерий `dense >= 0.40` — **при почти полном поле
  связная компонента фона сжимается**, и при плотности ниже 0.40 поле может
  не найтись вовсе. Комментарий стр. 358–360 признаёт, что прежний алгоритм
  «сжимал панель, когда несколько занятых строк разрывали её пробег».
- `runStrict` стр. 1862–1863: `if !useCachedBoard && visionFilled == 64` →
  `WAIT non-game screen` — **ровно 64 занятых клеток трактуется как «не игровой
  экран»** и цикл зацикливается. При 63 занятых (почти полное поле) проверка
  не срабатывает.
- `hasFullLine()` (стр. 1686–1690) и стр. 1868–1870: при наличии полной линии
  (кадр анимации очистки) — `WAIT line-clear frame` и пропуск.
- **Forced grid**: механизм `LOCKED_GRID` / `LOCK_FAILS` / `PENDING_GRID`
  (стр. 430–452). Блокировка снимается только после `LOCK_FAILS >= 15`
  (стр. 442). Комментарий стр. 431–436 прямо называет риск: сетка переиспользуется
  каждый цикл «без дрожания», но при реальном сдвиге поля бот до 15 кадров
  работает по устаревшей сетке.

### 5.4 Прочие подтверждённые проблемы

- **`externalSteeringMove` — блокирующий `Process` с жёстким лимитом 5 с**
  (стр. 789–791). При превышении `task.terminate()` и откат на внутренний решатель;
  на медленном поле это тихая деградация качества без явного лога.
- **`--once` объявлен, но не используется** (стр. 44).
- **Отсутствие git-истории blockbot** — версионирование копиями `.before_*`,
  что делает diff-анализ эволюции дорогим.
- **Нет README/документации** — `*.md` в каталоге не найдено.
- **Дублирование кода**: три почти идентичные Swift-версии (~2800 строк каждая),
  diff между ними ~126 строк; изменения приходится вносить трижды.
- **`runSolverSelfTest` ≠ покрытие**: проверяет 8 условий
  (`fullOK`, `impossibleOK`, `comboFresh/Mid/Spent`, `previewPair`,
  `restartSchedule`, `benchmarkScore`), но не касается ни захвата, ни drag,
  ни рестарта. `behavior_map_coverage` по проекту не строился.

---

## 6. Не найдено (явный список)

- Распознавание экрана проигрыша (game over).
- Закрытие рекламного окна (кнопка close/skip, OCR, AppleScript).
- Сбор монет / наград.
- Счётчик «3 игры» и цель «300 ходов».
- Обработка онбординга, ежедневных наград, магазина.
- `CGWindowListCreateImage` и любой API захвата без внешнего процесса.
- Vision / OCR / OpenCV / Core Image.
- README, документация, тесты.
- Git-история, относящаяся к blockbot.
