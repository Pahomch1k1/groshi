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
    name: "seven operations over two days → one confirmation",
    turns: [
      { user: "За 11 ноября добавь тысячу гривен на игры, 450 на пиццу, 300 в магазин, 1500 на бензин и 200 на такси. За 12 ноября добавь 800 гривен в ресторан и доход 15 тысяч за работу.", expect: { saved: 0, pending: 7 } },
      { user: "Да, сохраняй", expect: { saved: 7, pending: 0 } },
    ],
    expectTxs: [
      "2026-11-11|expense|1000|Games", "2026-11-11|expense|450|Restaurant/Cafe/Food", "2026-11-11|expense|300|Food",
      "2026-11-11|expense|1500|Gas", "2026-11-11|expense|200|Taxi", "2026-11-12|expense|800|Restaurant", "2026-11-12|income|15000|Salary",
    ],
  },
  {
    name: "corrections by voice before saving",
    turns: [
      { user: "Вчера 450 на пиццу, 300 в магазин и 200 на такси", expect: { saved: 0, pending: 3 } },
      { user: "Пиццу не 450, а 500, а такси убери", expect: { saved: 0, pending: 2 } },
      { user: "И ещё добавь 90 на мобильный за то же число", expect: { saved: 0, pending: 3 } },
      { user: "Подтверждаю", expect: { saved: 3 } },
    ],
    expectTxs: ["2026-11-19|expense|500|Restaurant/Cafe/Food", "2026-11-19|expense|300|Food", "2026-11-19|expense|90|Mobile number"],
  },
  {
    name: "cancel a draft",
    turns: [
      { user: "Сегодня 120 на кофе и 80 на сигареты", expect: { pending: 2 } },
      { user: "Нет, не надо, отмена", expect: { saved: 0, pending: 0 } },
    ],
    expectTxs: [],
  },
  ...[5, 10, 20, 30].map((n) => {
    const b = bulk(n);
    return {
      name: `${n} operations in one command`,
      turns: [{ user: b.text, expect: { saved: 0, pending: n } }, { button: "confirm" }],
      expectTxs: b.expect,
    };
  }),
  {
    name: "Ukrainian and English synonyms",
    turns: [
      { user: "Вчора витратив 300 гривень в аптеці і дві тисячі на одяг", expect: { pending: 2 } },
      { user: "Так, зберігай", expect: { saved: 2 } },
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
];
