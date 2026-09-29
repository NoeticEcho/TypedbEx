---
max_turns: 8
allowed_tools: [Skill]
---
TypeDB 3.12. I have this query and there are far too many results to take at once, so I want to page through it a thousand at a time:

    match $p isa person;
    fetch { "name": $p.name, "age": $p.age };

How do I page it?
