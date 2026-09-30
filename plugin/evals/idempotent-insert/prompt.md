---
max_turns: 8
allowed_tools: [Skill]
---
TypeDB 3.12. My schema is `entity person, owns name @key, owns age;`. I want a query I can run repeatedly for the same person without creating duplicates, and that also brings their age up to date. Alice is already stored with age 30 and I now know she is 31.
