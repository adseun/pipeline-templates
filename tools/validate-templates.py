"""Validate template integrity. jobTemplate/buildJobTemplate values are
parameters consumed by templates/stages/*.yml, so they resolve relative to
the stage template -- not relative to the file that writes them."""
import yaml,glob,os,re,sys
files=sorted(glob.glob('**/*.y*ml',recursive=True)); fail=0

bad=[]
for f in files:
    try: list(yaml.safe_load_all(open(f,encoding='utf-8')))
    except Exception as e: bad.append((f,str(e).split('\n')[0]))
print(f"1. YAML syntax          : {len(files)} files, {len(bad)} failures")
for f,e in bad: print("     FAIL",f,"|",e); 
fail+=len(bad)

b=c=0
for f in files:
    txt=open(f,encoding='utf-8').read()
    for m in re.finditer(r'\btemplate:\s*([^\s@#\'"]+\.ya?ml)',txt):
        t=m.group(1)
        if t.startswith('$') or '@' in t: continue
        c+=1
        if not os.path.exists(os.path.normpath(os.path.join(os.path.dirname(f),t))):
            print("     BROKEN",f,"->",t); b+=1
    # job templates resolve from the stage templates that consume them
    for m in re.finditer(r'\b(?:jobTemplate|buildJobTemplate):\s*([^\s@#\'"]+\.ya?ml)',txt):
        t=m.group(1)
        if t.startswith('$') or '@' in t: continue
        c+=1
        if not any(os.path.exists(os.path.normpath(os.path.join(d,t)))
                   for d in glob.glob('templates/stages')):
            print("     BROKEN(job)",f,"->",t); b+=1
print(f"2. template references  : {c} checked, {b} broken"); fail+=b

# 3. orphan check -- deletions can strand templates that nothing calls
allrefs=set()
for f in files:
    txt=open(f,encoding='utf-8').read()
    for m in re.finditer(r'\b(?:template|jobTemplate|buildJobTemplate):\s*([^\s@#\'"]+\.ya?ml)',txt):
        allrefs.add(os.path.basename(m.group(1)))
orph=[f for f in files if f.startswith('templates/') and os.path.basename(f) not in allrefs]
print(f"3. unreferenced templates: {len(orph)}")
for o in orph: print("     ORPHAN",o)
# orphans are reported, not failed: some are known-miswired rather than dead

dead=0
for f in glob.glob('**/*.md',recursive=True):
    for mm in re.finditer(r'\]\((\.\.?/[^)#]+)\)',open(f,encoding='utf-8').read()):
        if not os.path.exists(os.path.normpath(os.path.join(os.path.dirname(f),mm.group(1)))):
            print("     DEADLINK",f,"->",mm.group(1)); dead+=1
print(f"4. doc links            : {dead} dead"); fail+=dead
print("\nRESULT:", "PASS" if fail==0 else f"FAIL ({fail} issues)")
sys.exit(1 if fail else 0)
