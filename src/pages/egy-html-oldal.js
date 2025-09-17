import Head from 'next/head';

export default function EgyHtmlOldal() {
    return (
        <>
            <Head>
                <title>Egy egyszerű HTML oldal</title>
                <meta
                    name="description"
                    content="Egyszerű bemutató oldal, amely megmutatja, hogyan lehet statikus tartalmat készíteni a projekten belül."
                />
            </Head>
            <main className="min-h-screen bg-light text-dark py-16">
                <div className="mx-auto max-w-3xl px-6">
                    <header className="mb-12 text-center space-y-4">
                        <p className="text-sm uppercase tracking-widest text-primary">Bemutató oldal</p>
                        <h1 className="text-4xl font-semibold">Egy egyszerű HTML oldal</h1>
                        <p className="text-lg opacity-80">
                            Ez az oldal egy példát mutat arra, hogyan hozhatsz létre tartalmas, könnyen olvasható felületeket
                            egyszerű HTML elemekből és Tailwind CSS osztályokból.
                        </p>
                    </header>

                    <section className="mb-12 space-y-4">
                        <h2 className="text-2xl font-semibold">Miért készült ez az oldal?</h2>
                        <p>
                            Rövid bevezetőként szolgál a projektben található technológiákhoz. A cél az, hogy strukturáltan mutassa
                            be, milyen elemekből állhat egy információs oldal, és hogyan lehet azokat könnyen tovább bővíteni.
                        </p>
                        <ul className="list-disc space-y-2 pl-6">
                            <li>Egyszerű felépítésű példát kapj a tartalom szervezésére.</li>
                            <li>Megmutassa a Tailwind CSS osztályok gyakorlati használatát.</li>
                            <li>Kiindulási pontot adjon saját oldalak gyors létrehozásához.</li>
                        </ul>
                    </section>

                    <section className="mb-12 space-y-6">
                        <h2 className="text-2xl font-semibold">Oldal struktúrája</h2>
                        <p>
                            Az alábbi kártyák röviden összefoglalják, milyen tartalmi blokkok találhatók ezen az oldalon. Bármelyik
                            blokk könnyedén kicserélhető vagy átalakítható a saját igényeid szerint.
                        </p>
                        <div className="grid gap-6 sm:grid-cols-2">
                            <article className="rounded-xl border border-neutral bg-white p-6 shadow-sm">
                                <h3 className="text-xl font-semibold">Információs rész</h3>
                                <p className="mt-3 opacity-80">
                                    Részletes leírás, amely elmagyarázza az oldal célját, és további kontextust biztosít a
                                    látogatóknak.
                                </p>
                            </article>
                            <article className="rounded-xl border border-neutral bg-white p-6 shadow-sm">
                                <h3 className="text-xl font-semibold">Listák és felsorolások</h3>
                                <p className="mt-3 opacity-80">
                                    Pontokba szedve könnyen áttekinthető módon sorolhatod fel a legfontosabb üzeneteket vagy
                                    tennivalókat.
                                </p>
                            </article>
                            <article className="rounded-xl border border-neutral bg-white p-6 shadow-sm">
                                <h3 className="text-xl font-semibold">Idézetek</h3>
                                <p className="mt-3 opacity-80">
                                    Kiemelt idézetek segítenek inspirációt adni, vagy kiemelni egy fontos gondolatot a tartalomban.
                                </p>
                            </article>
                            <article className="rounded-xl border border-neutral bg-white p-6 shadow-sm">
                                <h3 className="text-xl font-semibold">Cselekvésre ösztönzés</h3>
                                <p className="mt-3 opacity-80">
                                    Egy gomb vagy hivatkozás, amely a következő lépés megtételére hívja fel a figyelmet.
                                </p>
                            </article>
                        </div>
                    </section>

                    <section className="mb-12 space-y-4">
                        <h2 className="text-2xl font-semibold">Kiemelt gondolat</h2>
                        <blockquote className="rounded-xl border-l-4 border-primary bg-neutral p-6 italic">
                            "A jól felépített tartalom segít a látogatóknak gyorsan megérteni az üzenetedet, és motiválja őket a
                            további felfedezésre."
                        </blockquote>
                        <p>
                            Egy idézet vagy mottó remekül használható arra, hogy érzelmi kapcsolatot alakítson ki az olvasókkal. Ez
                            az oldal azt illusztrálja, mennyire könnyedén beépíthető egy ilyen elem.
                        </p>
                    </section>

                    <section className="rounded-2xl bg-primary px-10 py-12 text-center text-light">
                        <h2 className="text-2xl font-semibold">Készen állsz a következő lépésre?</h2>
                        <p className="mt-4 opacity-90">
                            Építsd be ezt a struktúrát a saját projektedbe, és alakítsd át a saját történetedre szabva!
                        </p>
                        <a
                            href="/"
                            className="sb-component-button sb-component-button-primary mt-6 inline-flex items-center justify-center border-transparent bg-light px-8 py-3 font-semibold text-primary transition hover:-translate-y-1"
                        >
                            Vissza a főoldalra
                        </a>
                    </section>
                </div>
            </main>
        </>
    );
}
