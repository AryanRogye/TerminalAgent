# Dependencies

This repository depends on Lib Ghostty 

### Instructions
```bash
git clone git@github.com:ghostty-org/ghostty.git # Clone Repo
cd ghostty                                       
zig build                                        # Build Repo 
```

This generates a `zig-out` With what we need, 
Now move the generated files into the root of this repository

```bash
mv zig-out/include /path/to/your/project/include
mv zig-out/lib/libghostty-vt.a /path/to/your/project/libghostty-vt.a
```

Replace `/path/to/your/project` with the root directory of this repository
