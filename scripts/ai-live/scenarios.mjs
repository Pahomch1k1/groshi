// Voice-style commands for the live OpenAI check. "Now" in the contract is Friday 2026-11-20 10:00 (Kyiv).
// expectTxs: "YYYY-MM-DD|kind|amount|Category[/Alternative]" — the saved operations at the end.

const pool = [
  ["на такси", "Taxi"], ["на бензин", "Gas"], ["в аптеке", "Pharmacy"], ["на игры", "Games"], ["на одежду", "Clothes"],
  ["на продукты", "Food"], ["за парковку", "Parking"], ["на стрижку", "Haircut"], ["в кино", "Cinema"], ["на сигареты", "Cigarettes"],
  ["у ветеринара", "Veterinary"], ["в баре", "Bar"], ["за отель", "Hotel"], ["на мобильный", "Mobile number"], ["у стоматолога", "Dental"],
  ["на ремонт", "Repair"], ["на подарки", "Gifts"], ["на почту", "Post"], ["на кофе", "Cafe"], ["на лего", "Lego"],
];
const ruMonthDay = (d) => `${d} ноября`;

// n operations spread over several days: "За 3 ноября: 120 на такси, 145 на бензин. За 4 ноября: ..."
function bulk(n) {
  const days = [3, 4, 5, 6, 7, 9, 10];
  const perDay = Math.ceil(n / days.length) || 1;
  const parts = [], expect = [];
  for (let i = 0, d = 0; i < n; d++) {
    const chunk = [];
    for (let k = 0; k < perDay && i < n; k++, i++) {
      const [word, cat] = pool[i % pool.length];
      const amount = 100 + i * 15;
      chunk.push(`${amount} ${word}`);
      expect.push(`2026-11-${String(days[d]).padStart(2, "0")}|expense|${amount}|${cat}`);
    }
    parts.push(`За ${ruMonthDay(days[d])}: ${chunk.join(", ")}.`);
  }
  return { text: parts.join(" "), expect };
}

export const scenarios = [
  {
    name: "single without date → asks date → saves",
    turns: [
      { user: "Добавь расход: тысяча гривен на игры", expect: { saved: 0, asks: true } },
      { user: "За 11 ноября", expect: { saved: 1, pending: 0 } },
    ],
    expectTxs: ["2026-11-11|expense|1000|Games"],
  },
  {
    name: "three operations are saved at once",
    turns: [{ user: "За 19 ноября добавь 1000 гривен на игры, 500 на такси и 300 на продукты", expect: { saved: 3, pending: 0 } }],
    expectTxs: ["2026-11-19|expense|1000|Games", "2026-11-19|expense|500|Taxi", "2026-11-19|expense|300|Food"],
  },
  {
    // 0.5: a draft collected over several dictations (app switches in between), sent once.
    name: "voice draft of three dictations: dates carry over until a new one",
    turns: [{ user: "14 ноября ресторан 850 грн, продукты 320 грн, 15 ноября кофе 120 грн, такси 250 грн, вчера доставка еды 400", expect: { saved: 5, pending: 0 } }],
    expectTxs: [
      "2026-11-14|expense|850|Restaurant", "2026-11-14|expense|320|Food", "2026-11-15|expense|120|Cafe/Restaurant",
      "2026-11-15|expense|250|Taxi", "2026-11-19|expense|400|Food/Restaurant/Cafe",
    ],
  },
  {
    name: "seven operations over two days are saved at once",
    turns: [
      { user: "За 11 ноября добавь тысячу гривен на игры, 450 на пиццу, 300 в магазин, 1500 на бензин и 200 на такси. За 12 ноября добавь 800 гривен в ресторан и доход 15 тысяч за работу.", expect: { saved: 7, pending: 0 } },
    ],
    expectTxs: [
      "2026-11-11|expense|1000|Games", "2026-11-11|expense|450|Restaurant/Cafe/Food", "2026-11-11|expense|300|Food",
      "2026-11-11|expense|1500|Gas", "2026-11-11|expense|200|Taxi", "2026-11-12|expense|800|Restaurant", "2026-11-12|income|15000|Salary",
    ],
  },
  {
    name: "corrections by voice after saving",
    turns: [
      { user: "Вчера 450 на пиццу, 300 в магазин и 200 на такси", expect: { saved: 3 } },
      { user: "Пиццу не 450, а 500, а такси убери", expect: { saved: 2, pending: 0 } },
      { user: "И ещё добавь 90 на мобильный за то же число", expect: { saved: 3 } },
    ],
    expectTxs: ["2026-11-19|expense|500|Restaurant/Cafe/Food", "2026-11-19|expense|300|Food", "2026-11-19|expense|90|Mobile number"],
  },
  {
    name: "repeated command asks about a duplicate",
    turns: [
      { user: "Сегодня 120 на кофе и 80 на сигареты", expect: { saved: 2 } },
      { user: "Сегодня 120 на кофе и 80 на сигареты", expect: { saved: 2, asks: true } },
      { user: "Нет, это повтор, не добавляй", expect: { saved: 2, pending: 0 } },
    ],
    expectTxs: ["2026-11-20|expense|120|Cafe", "2026-11-20|expense|80|Cigarettes"],
  },
  ...[5, 10, 20, 30].map((n) => {
    const b = bulk(n);
    return { name: `${n} operations in one command`, turns: [{ user: b.text, expect: { saved: n, pending: 0 } }], expectTxs: b.expect };
  }),
  {
    name: "Ukrainian and English synonyms",
    turns: [
      { user: "Вчора витратив 300 гривень в аптеці і дві тисячі на одяг", expect: { saved: 2 } },
      { user: "Spent 500 on a taxi today", expect: { saved: 3 } },
    ],
    expectTxs: ["2026-11-19|expense|300|Pharmacy", "2026-11-19|expense|2000|Clothes", "2026-11-20|expense|500|Taxi"],
  },
  {
    name: "missing amount → asks, then saves",
    turns: [
      { user: "Запиши сегодня расход на бензин", expect: { saved: 0, asks: true } },
      { user: "Тысяча двести", expect: { saved: 1 } },
    ],
    expectTxs: ["2026-11-20|expense|1200|Gas"],
  },
  {
    name: "undo last action",
    turns: [
      { user: "Сегодня 350 на парковку", expect: { saved: 1 } },
      { user: "Отмени последнее действие", expect: { saved: 0 } },
    ],
    expectTxs: [],
  },
  {
    name: "category by voice, no automatic categories",
    turns: [
      { user: "Сегодня 600 на бензин", expect: { saved: 1, noCreateCategory: true } },
      { user: "Создай категорию расходов Кальян", expect: {} },
      { user: "Добавь 400 на кальян сегодня", expect: { saved: 2 } },
    ],
    expectCategory: "Кальян",
    expectTxs: ["2026-11-20|expense|600|Gas", "2026-11-20|expense|400|Кальян"],
  },
  {
    name: "category order by voice",
    turns: [
      { user: "Поставь Games на первое место", expect: { order: ["pos:Games=1"] } },
      { user: "Перемести Taxi во вторую строку на третье место", expect: { order: ["pos:Taxi=7", "pos:Games=1"] } },
      { user: "Поставь Cafe после Gas", expect: { order: ["after:Cafe=Gas"] } },
      { user: "Поменяй местами Food и Gas", expect: { order: ["swap:Food=Gas"] } },
      { user: "Создай категорию Кальян и поставь её в начало списка", expect: { order: ["pos:Кальян=1"] } },
    ],
    expectCategory: "Кальян",
    expectTxs: [],
  },
];
