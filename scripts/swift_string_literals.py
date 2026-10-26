"""Small Swift string lexer for localization auditing; does not rewrite code."""
from pathlib import Path
import re,json
CJK=re.compile('[\u3400-\u9fff]')
def quote(src,i):
 start=i;raw=''
 while i<len(src) and src[i]=='#':raw+='#';i+=1
 if i>=len(src) or src[i]!='"':return None
 triple=src.startswith('"""',i); delim=('"""' if triple else '"')+raw;i+=3 if triple else 1
 parts=[];lit='';mark='\\'+raw
 while i<len(src):
  if src.startswith(delim,i):parts.append(('literal',lit));return i+len(delim),parts,triple,raw
  if src.startswith(mark+'(',i):
   parts.append(('literal',lit));lit='';a=i+len(mark)+1;j=a;depth=1
   while j<len(src) and depth:
    if src.startswith('//',j):j=src.find('\n',j);continue
    if src[j]=='"' or (src[j]=='#' and re.match(r'#+"',src[j:])):
     q=quote(src,j);j=q[0];continue
    if src[j]=='(':depth+=1
    elif src[j]==')':depth-=1
    j+=1
   parts.append(('expression',src[a:j-1]));i=j;continue
  if not raw and src[i]=='\\' and i+1<len(src):lit+=src[i:i+2];i+=2;continue
  lit+=src[i];i+=1
 raise ValueError(('unclosed',start,src[start:start+80]))
def strings(src,offset=0):
 i=0
 while i<len(src):
  if src.startswith('//',i):
   n=src.find('\n',i);i=n if n!=-1 else len(src);continue
  if src.startswith('/*',i):
   dep=1;i+=2
   while i<len(src) and dep:
    if src.startswith('/*',i):dep+=1;i+=2
    elif src.startswith('*/',i):dep-=1;i+=2
    else:i+=1
   continue
  if src[i]=='"' or (src[i]=='#' and re.match(r'#+"',src[i:])):
   q=quote(src,i);end,parts,triple,raw=q
   yield {'start':offset+i,'end':offset+end,'parts':parts,'triple':triple,'rawDelimiter':raw,'source':src[i:end]}
   i=end;continue
  i+=1
