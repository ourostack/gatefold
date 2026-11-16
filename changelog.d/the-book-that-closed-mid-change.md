---
title: The Book That Closed Mid-Change
kind: fix
try: Change the text size in Fine-Tune and close the book right away.
---
A book closed in the very second its new size was being set could take the whole app down with it, because the page went looking for a reader that had already left. Now it checks that the reader is still there before it asks, and a quick close is just a close.
