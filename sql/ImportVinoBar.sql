USE `Sql467031_5`;

-- Import vini/bar/liquori dall'estrazione menu.CSV del POS attivo.
-- Esclusi dall'importazione: righe "[V] ..." (modificatori/opzioni a prezzo zero, non prodotti
-- reali), voci amministrative/canale a 0 euro (NON FARE, Just Eat, UBER EAT, ecc. - fuori scope,
-- non sono vini/bar), e duplicati identificati (Singha/Chang gia' presenti come "Singha Beer"/
-- "Chang Beer"; Fragolino/Moscato fragolino/Cocktail presenti due volte nel CSV stesso).
-- Tutti i nuovi prodotti: is_active=1 (utilizzabili subito in sala), is_delivery=0 (non esposti
-- a HubRise/piattaforme delivery: da rivedere manualmente se si vuole rendere consegnabile
-- qualcosa, es. acqua/bibite in bottiglia).
-- Le nuove categorie sono is_visible=0, come la categoria "Bevande" gia' esistente (non visibili
-- sul menu online pubblico, ma disponibili nell'app interna di gestione comande).

INSERT INTO v2_categories (name_it, name_en, sort_order, is_visible) VALUES
('Vini Bianchi', 'White Wines', 92, 0),
('Vini Rossi', 'Red Wines', 93, 0),
('Vini Rosati', 'Rosé Wines', 94, 0),
('Spumanti', 'Sparkling Wines', 95, 0),
('Liquori', 'Spirits', 96, 0);

-- I product INSERT usano i category_id assegnati sopra (recuperati a runtime: vedi note di
-- esecuzione, i valori letterali qui sotto vanno sostituiti se le nuove categorie prendono id
-- diversi da 11-15).

-- Bar (categoria 10, "Bevande", gia' esistente)
INSERT INTO v2_products (category_id, name, description_it, description_en, price, spiciness_level, image_url, is_active, is_delivery) VALUES
(10, 'Acqua lete', '', '', 2.50, 0, '', 1, 0),
(10, 'Acqua Naturale', '', '', 2.50, 0, '', 1, 0),
(10, 'Acqua piccola', '', '', 1.00, 0, '', 1, 0),
(10, 'Acqua frizzante', '', '', 2.50, 0, '', 1, 0),
(10, 'Amaro', '', '', 4.00, 0, '', 1, 0),
(10, 'Amaro Amara', '', '', 6.00, 0, '', 1, 0),
(10, 'Amaro Jefferson', '', '', 5.00, 0, '', 1, 0),
(10, 'Beck''s', '', '', 4.00, 0, '', 1, 0),
(10, 'Caffè', '', '', 1.00, 0, '', 1, 0),
(10, 'Calice B.co', '', '', 6.00, 0, '', 1, 0),
(10, 'Calice Fragolino', '', '', 5.00, 0, '', 1, 0),
(10, 'Calice rosso', '', '', 6.00, 0, '', 1, 0),
(10, 'Chinotto', '', '', 1.50, 0, '', 1, 0),
(10, 'Coca G.', '', '', 5.00, 0, '', 1, 0),
(10, 'Coca P.', '', '', 2.50, 0, '', 1, 0),
(10, 'Coca zero', '', '', 2.50, 0, '', 1, 0),
(10, 'Cocktail', '', '', 6.00, 0, '', 1, 0),
(10, 'Fanta', '', '', 2.50, 0, '', 1, 0),
(10, 'Heineken', '', '', 3.00, 0, '', 1, 0),
(10, 'Ice Coffee', '', '', 2.00, 0, '', 1, 0),
(10, 'Singha 66cl', '', '', 8.00, 0, '', 1, 0),
(10, 'Sorbetto', '', '', 2.00, 0, '', 1, 0),
(10, 'Sprite', '', '', 2.50, 0, '', 1, 0),
(10, 'Succo di frutta', '', '', 2.00, 0, '', 1, 0),
(10, 'Thai Hot tea', '', '', 2.50, 0, '', 1, 0),
(10, 'Thai Ice Tea', '', '', 2.50, 0, '', 1, 0),
(10, 'Thai Iced coffee', '', '', 2.50, 0, '', 1, 0);

-- Vini Bianchi
INSERT INTO v2_products (category_id, name, description_it, description_en, price, spiciness_level, image_url, is_active, is_delivery) VALUES
(11, 'Acate Grillo Zagra', '', '', 20.00, 0, '', 1, 0),
(11, 'Acate Insolia', '', '', 20.00, 0, '', 1, 0),
(11, 'Bisi Il Peccatore', '', '', 20.00, 0, '', 1, 0),
(11, 'Collio Sauvignon', '', '', 35.00, 0, '', 1, 0),
(11, 'Cusumano Alcamo', '', '', 15.00, 0, '', 1, 0),
(11, 'Cusumano Alta Etna B.co', '', '', 20.00, 0, '', 1, 0),
(11, 'Cusumano Angimbè', '', '', 18.00, 0, '', 1, 0),
(11, 'Cusumano Cubia', '', '', 16.00, 0, '', 1, 0),
(11, 'Cusumano Jalè', '', '', 18.00, 0, '', 1, 0),
(11, 'Cusumano Shamaris', '', '', 16.00, 0, '', 1, 0),
(11, 'Destro isolaNuda', '', '', 18.00, 0, '', 1, 0),
(11, 'Firriato Charme B.co', '', '', 20.00, 0, '', 1, 0),
(11, 'Firriato Quater Bianco', '', '', 22.00, 0, '', 1, 0),
(11, 'Graci Etna B.co', '', '', 30.00, 0, '', 1, 0),
(11, 'Maria Costanza B.co', '', '', 25.00, 0, '', 1, 0),
(11, 'Maso Cantang', '', '', 25.00, 0, '', 1, 0),
(11, 'Masseria Grillo', '', '', 20.00, 0, '', 1, 0),
(11, 'Masseria Hermosa Grillo', '', '', 22.00, 0, '', 1, 0),
(11, 'Milazzo B.co di Nera', '', '', 22.00, 0, '', 1, 0),
(11, 'Milazzo Baronia', '', '', 25.00, 0, '', 1, 0),
(11, 'Milazzo Svevo B', '', '', 20.00, 0, '', 1, 0),
(11, 'Molino Chardonnay', '', '', 18.00, 0, '', 1, 0),
(11, 'Molino Pinot G.', '', '', 18.00, 0, '', 1, 0),
(11, 'Molino Sauvignon Blanc', '', '', 18.00, 0, '', 1, 0),
(11, 'Molino Traminer', '', '', 18.00, 0, '', 1, 0),
(11, 'Muller Thurgau Gewurtz', '', '', 22.00, 0, '', 1, 0),
(11, 'Muller Thurgau Terre', '', '', 22.00, 0, '', 1, 0),
(11, 'Raetia Sauvignon', '', '', 18.00, 0, '', 1, 0),
(11, 'Santi Chiaro di Luna', '', '', 16.00, 0, '', 1, 0),
(11, 'Tasca Buonora', '', '', 20.00, 0, '', 1, 0),
(11, 'Tasca Grillo', '', '', 22.00, 0, '', 1, 0),
(11, 'Tasca Leone', '', '', 25.00, 0, '', 1, 0);

-- Vini Rossi
INSERT INTO v2_products (category_id, name, description_it, description_en, price, spiciness_level, image_url, is_active, is_delivery) VALUES
(12, 'Acate Cerasuolo', '', '', 22.00, 0, '', 1, 0),
(12, 'Acate Frappato', '', '', 22.00, 0, '', 1, 0),
(12, 'Amarone Valpolicella', '', '', 60.00, 0, '', 1, 0),
(12, 'Brunello di Montalcino', '', '', 50.00, 0, '', 1, 0),
(12, 'Chateau Ronan Rosso', '', '', 28.00, 0, '', 1, 0),
(12, 'Corino Barolo', '', '', 50.00, 0, '', 1, 0),
(12, 'Corino Dolcetto d''Alba', '', '', 20.00, 0, '', 1, 0),
(12, 'Costanzo Mofete', '', '', 20.00, 0, '', 1, 0),
(12, 'Cusumano Benuara', '', '', 20.00, 0, '', 1, 0),
(12, 'Cusumano Merlot', '', '', 15.00, 0, '', 1, 0),
(12, 'Cusumano Noà', '', '', 35.00, 0, '', 1, 0),
(12, 'Cusumano Sàgana', '', '', 35.00, 0, '', 1, 0),
(12, 'Desueri Cusumano Nero D''Avola', '', '', 20.00, 0, '', 1, 0),
(12, 'Firriato Corte Maharajà', '', '', 20.00, 0, '', 1, 0),
(12, 'Firriato Harmonium', '', '', 29.00, 0, '', 1, 0),
(12, 'Firriato Le Sabbie', '', '', 22.00, 0, '', 1, 0),
(12, 'Firriato Quater Rosso', '', '', 26.00, 0, '', 1, 0),
(12, 'Firriato Sant''Agostino', '', '', 25.00, 0, '', 1, 0),
(12, 'Firriato Sorià', '', '', 20.00, 0, '', 1, 0),
(12, 'Graci Etna Rosso', '', '', 30.00, 0, '', 1, 0),
(12, 'Maru Negroamaro', '', '', 25.00, 0, '', 1, 0),
(12, 'Meme Chianti', '', '', 25.00, 0, '', 1, 0),
(12, 'Merlot di Leonardo', '', '', 18.00, 0, '', 1, 0),
(12, 'Milazzo Maria C. R.', '', '', 35.00, 0, '', 1, 0),
(12, 'Milazzo Svevo R', '', '', 22.00, 0, '', 1, 0),
(12, 'Mofete Etna R.', '', '', 20.00, 0, '', 1, 0),
(12, 'Molino C.F.', '', '', 18.00, 0, '', 1, 0),
(12, 'Molino C.S.', '', '', 18.00, 0, '', 1, 0),
(12, 'Molino Merlot', '', '', 18.00, 0, '', 1, 0),
(12, 'Molino Pinot Nero', '', '', 18.00, 0, '', 1, 0),
(12, 'Moscato d''Asti Galletto', '', '', 20.00, 0, '', 1, 0),
(12, 'Nanfro Frappato', '', '', 18.00, 0, '', 1, 0),
(12, 'Nanfro Sammauro', '', '', 20.00, 0, '', 1, 0),
(12, 'Piluna Primitivo', '', '', 25.00, 0, '', 1, 0),
(12, 'Ronan rosso', '', '', 20.00, 0, '', 1, 0),
(12, 'Sirah Masseria del Feudo', '', '', 20.00, 0, '', 1, 0),
(12, 'Sisa Nero d''Avola', '', '', 15.00, 0, '', 1, 0),
(12, 'Tasca Cignus', '', '', 29.00, 0, '', 1, 0),
(12, 'Tasca Ghiaia N', '', '', 20.00, 0, '', 1, 0),
(12, 'Tasca Lamuri', '', '', 20.00, 0, '', 1, 0),
(12, 'Tenimenti Barolo', '', '', 38.00, 0, '', 1, 0),
(12, 'Valpolicella Duca Fedele', '', '', 25.00, 0, '', 1, 0),
(12, 'Via Rossa', '', '', 20.00, 0, '', 1, 0);

-- Vini Rosati
INSERT INTO v2_products (category_id, name, description_it, description_en, price, spiciness_level, image_url, is_active, is_delivery) VALUES
(13, 'Cusumano Ramusa', '', '', 15.00, 0, '', 1, 0),
(13, 'Firriato Charme rosé', '', '', 20.00, 0, '', 1, 0),
(13, 'Fragolino', '', '', 12.00, 0, '', 1, 0),
(13, 'Milazzo Rosé di Rosa', '', '', 18.00, 0, '', 1, 0),
(13, 'Molino cab Rosé', '', '', 18.00, 0, '', 1, 0),
(13, 'Moscato', '', '', 12.00, 0, '', 1, 0),
(13, 'Moscato fragolino', '', '', 12.00, 0, '', 1, 0),
(13, 'Piemonte Brachetto', '', '', 20.00, 0, '', 1, 0);

-- Spumanti
INSERT INTO v2_products (category_id, name, description_it, description_en, price, spiciness_level, image_url, is_active, is_delivery) VALUES
(14, 'Champ. Brut reserve', '', '', 55.00, 0, '', 1, 0),
(14, 'Franciacorta', '', '', 35.00, 0, '', 1, 0),
(14, 'Motivo Brut', '', '', 20.00, 0, '', 1, 0),
(14, 'Valdob. Cartizze', '', '', 28.00, 0, '', 1, 0),
(14, 'Valdob. Cuvée', '', '', 20.00, 0, '', 1, 0),
(14, 'Valdob. Mill. Brut', '', '', 22.00, 0, '', 1, 0),
(14, 'Valdob. Millesimato D.', '', '', 20.00, 0, '', 1, 0),
(14, 'Valdob. Millesimato E. D.', '', '', 22.00, 0, '', 1, 0);

-- Liquori (Cocktail escluso: gia' aggiunto sotto Bevande, stesso nome/prezzo nel CSV originale)
INSERT INTO v2_products (category_id, name, description_it, description_en, price, spiciness_level, image_url, is_active, is_delivery) VALUES
(15, 'Amara', '', '', 4.00, 0, '', 1, 0),
(15, 'Averna', '', '', 4.00, 0, '', 1, 0),
(15, 'BenRiach whisky', '', '', 8.00, 0, '', 1, 0),
(15, 'Brandy Thai', '', '', 5.00, 0, '', 1, 0),
(15, 'Cannellino', '', '', 3.00, 0, '', 1, 0),
(15, 'Caolila', '', '', 8.00, 0, '', 1, 0),
(15, 'Del Capo', '', '', 4.00, 0, '', 1, 0),
(15, 'Fernet', '', '', 4.00, 0, '', 1, 0),
(15, 'Grappa', '', '', 4.00, 0, '', 1, 0),
(15, 'Grappa Barrique', '', '', 5.00, 0, '', 1, 0),
(15, 'Jack doppio', '', '', 8.00, 0, '', 1, 0),
(15, 'Jagemeister', '', '', 4.00, 0, '', 1, 0),
(15, 'Limoncello', '', '', 3.00, 0, '', 1, 0),
(15, 'Mekkong', '', '', 4.00, 0, '', 1, 0),
(15, 'Montenegro', '', '', 4.00, 0, '', 1, 0),
(15, 'Petrus', '', '', 4.00, 0, '', 1, 0),
(15, 'Sambuca', '', '', 4.00, 0, '', 1, 0),
(15, 'SangSom', '', '', 5.00, 0, '', 1, 0),
(15, 'Shot', '', '', 2.00, 0, '', 1, 0),
(15, 'Talisker whisky', '', '', 8.00, 0, '', 1, 0),
(15, 'Unicum', '', '', 4.00, 0, '', 1, 0),
(15, 'Whisky', '', '', 5.00, 0, '', 1, 0);
