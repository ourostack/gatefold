---
title: The Page That Split in Two
kind: fix
try: Read on the Duo's folded cover screen or an upright iPad: the page is always one column.
---
In our own review runs, a page on the Duo's folded cover screen, and on an upright iPad, tore down the middle into two cramped columns of four words a line, and stayed torn through every fold, scrub and trip to Contents. The culprit was a hidden switch meant only for our automated tests, which a tap at the top of the page could hit; your builds never had it. The switch now hides unless a test asks for it, and the reader refuses to set two pages side by side on any screen too narrow or too tall to hold them.
