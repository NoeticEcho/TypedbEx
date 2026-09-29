---
max_turns: 8
allowed_tools: [Skill]
---
My TypeDB 3.12 server rejects this and I can't see why — `dog` is the type I'm defining, right there on the line it complains about.

    define dog sub entity, owns name;

    [SYR1] The type 'dog' was not found.
    [DEX3] Failed to find symbol.

What's wrong?
