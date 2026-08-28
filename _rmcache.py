import shutil, os
for d in [
    r"D:\projects\sla\sa_plugin_db\.zig-cache\o\6daac3d495ae596f830f45054fc6a6e4",
    r"D:\projects\sla\sa_plugin_db\.zig-cache\o\912b547b454b370e1c9202b7f277981f",
]:
    if os.path.exists(d):
        shutil.rmtree(d)
        print("removed", d)
    else:
        print("not found", d)
