"""Regenerate the Casement icon family. Requires Pillow; native exports also need Icon Composer."""

from pathlib import Path
import argparse
import json
import shutil
import subprocess
import tempfile
from PIL import Image, ImageDraw

BRAND = Path(__file__).resolve().parent
REPO = BRAND.parent
ROOT = None
ICTOOL = '/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool'
SIZE = 1024
FRAME = 'M 706 200 H 298 Q 184 200 184 314 V 710 Q 184 824 298 824 H 706 V 696 H 338 Q 312 696 312 670 V 354 Q 312 328 338 328 H 706 Z'
PANE = 'M 738 240 L 868 350 V 674 L 738 784 Z'
SCREEN = 'M 402 426 H 566 Q 590 426 590 450 V 574 Q 590 598 566 598 H 402 Q 378 598 378 574 V 450 Q 378 426 402 426 Z'
FRAME_POINTS = [(706,200),(298,200)]

def quad(points, control, end):
    start = points[-1]
    for i in range(1,33):
        t = i / 32
        points.append(((1-t)**2*start[0]+2*(1-t)*t*control[0]+t*t*end[0],
                       (1-t)**2*start[1]+2*(1-t)*t*control[1]+t*t*end[1]))

quad(FRAME_POINTS,(184,200),(184,314))
FRAME_POINTS.append((184,710))
quad(FRAME_POINTS,(184,824),(298,824))
FRAME_POINTS += [(706,824),(706,696),(338,696)]
quad(FRAME_POINTS,(312,696),(312,670))
FRAME_POINTS.append((312,354))
quad(FRAME_POINTS,(312,328),(338,328))
FRAME_POINTS.append((706,328))

FAMILY = {
    'Casement': {
        'slug':'casement', 'bg':'#F3EDF5', 'dark_bg':'#17121D',
        'frame':'#62346F', 'dark_frame':'#B392CE',
        'pane':'#9A76BA', 'dark_pane':'#D1B5EB',
    },
    'CasementHost': {
        'slug':'casement-host', 'bg':'#EAF0F2', 'dark_bg':'#141B22',
        'frame':'#344D61', 'dark_frame':'#A6C4D7',
        'pane':'#7697AD', 'dark_pane':'#C0D9E8',
        'screen':'#536F82', 'dark_screen':'#88ACC4',
    },
}

def srgb(color):
    rgb = [int(color[i:i+2],16)/255 for i in (1,3,5)]
    return 'extended-srgb:' + ','.join(f'{v:.6f}' for v in [*rgb,1])

def specialized(light,dark,mono=False):
    values=[{'value':{'solid':srgb(light)}},
            {'appearance':'dark','value':{'solid':srgb(dark)}}]
    if mono:
        # The document format calls Icon Composer's mono appearance "tinted".
        # A white source prevents dark default-brand colors from disappearing here.
        values.append({'appearance':'tinted','value':{'solid':srgb('#FFFFFF')}})
    return values

def layer_image(kind,color,scale=4):
    im=Image.new('RGBA',(SIZE*scale,SIZE*scale))
    d=ImageDraw.Draw(im)
    if kind=='frame':
        d.polygon([(round(x*scale),round(y*scale)) for x,y in FRAME_POINTS],fill=color)
    elif kind=='pane':
        d.polygon([(738*scale,240*scale),(868*scale,350*scale),(868*scale,674*scale),(738*scale,784*scale)],fill=color)
    else:
        d.rounded_rectangle((378*scale,426*scale,590*scale,598*scale),radius=24*scale,fill=color)
    return im.resize((SIZE,SIZE),Image.Resampling.LANCZOS)

def write_icon(name,style):
    icon=ROOT/(name+'.icon')
    assets=icon/'Assets'
    assets.mkdir(parents=True,exist_ok=True)
    # Icon Composer's groups are ordered front to back, matching the maintained project documents.
    kinds=['pane'] + (['screen'] if 'screen' in style else []) + ['frame']
    groups=[]
    for kind in kinds:
        path={'frame':FRAME,'pane':PANE,'screen':SCREEN}[kind]
        (assets/(kind+'.svg')).write_text(f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024"><path fill="white" d="{path}"/></svg>\n')
        groups.append({
            'name':kind.title(),
            'layers':[{'name':kind,'image-name':kind+'.svg','glass':True,
                       'fill-specializations':specialized(style[kind],style['dark_'+kind],mono=True)}],
            'shadow':{'kind':'neutral','opacity':0.18},
            'translucency':{'enabled':False,'value':0.5},
            'specular':True,'lighting':'combined',
        })
    (icon/'icon.json').write_text(json.dumps({
        'fill-specializations':specialized(style['bg'],style['dark_bg']),
        'groups':groups,'supported-platforms':{'squares':'shared'},
    },indent=2)+'\n')
    return icon

def flat(name,style,dark=False,transparent=False):
    prefix='dark_' if dark else ''
    result=Image.new('RGBA',(SIZE,SIZE),(0,0,0,0) if transparent else style[prefix+'bg'])
    for kind in ['frame','screen','pane']:
        if kind not in style: continue
        result.alpha_composite(layer_image(kind,style[prefix+kind]))
    return result

def visionos(style):
    stack=ROOT/'visionos'/'Assets.xcassets'/'AppIcon.solidimagestack'
    stack.mkdir(parents=True,exist_ok=True)
    info={'author':'xcode','version':1}
    (stack.parent/'Contents.json').write_text(json.dumps({'info':info},indent=2)+'\n')
    (stack/'Contents.json').write_text(json.dumps({'info':info,'layers':[{'filename':f'{n}.solidimagestacklayer'} for n in ['Front','Middle','Back']]},indent=2)+'\n')
    for name,kind in [('Front','pane'),('Middle','frame'),('Back','background')]:
        layer=stack/(name+'.solidimagestacklayer')
        content=layer/'Content.imageset'
        content.mkdir(parents=True,exist_ok=True)
        filename=name.lower()+'.png'
        (layer/'Contents.json').write_text(json.dumps({'info':info},indent=2)+'\n')
        (content/'Contents.json').write_text(json.dumps({'info':info,'images':[{'filename':filename,'idiom':'vision','scale':'2x'}]},indent=2)+'\n')
        im=Image.new('RGB',(SIZE,SIZE),style['bg']) if kind=='background' else layer_image(kind,style[kind])
        im.save(content/filename,optimize=True)
    preview=flat('Casement',style)
    mask=Image.new('L',(SIZE*4,SIZE*4))
    ImageDraw.Draw(mask).ellipse((0,0,SIZE*4-1,SIZE*4-1),fill=255)
    preview.putalpha(mask.resize((SIZE,SIZE),Image.Resampling.LANCZOS))
    preview.save(ROOT/'visionos'/'circular-layout-check.png',optimize=True)

def windows(style):
    out=ROOT/'windows'; out.mkdir(exist_ok=True)
    sizes=[16,20,24,32,40,48,64,96,128,256]
    for dark in [False,True]:
        mode='dark' if dark else 'light'
        im=flat('CasementHost',style,dark=dark,transparent=True)
        im.save(out/f'casement-host-{mode}.ico',sizes=[(n,n) for n in sizes])
        im.save(out/f'casement-host-{mode}-1024.png',optimize=True)
        for n in sizes:
            im.resize((n,n),Image.Resampling.LANCZOS).save(out/f'host-{mode}-{n}.png',optimize=True)
    # An exe's ICO cannot select a theme by itself. Use a middle-value frame with
    # useful contrast against both light and dark shell surfaces.
    balanced={**style,'frame':'#6E8292','pane':'#AAC4D4','screen':'#6E8292'}
    icon=flat('CasementHost',balanced,transparent=True)
    icon.save(out/'casement-host.ico',sizes=[(n,n) for n in sizes])
    icon.save(out/'casement-host-balanced-1024.png',optimize=True)
    for mode,color in [('light','#1B2430'),('dark','#F2F4F7')]:
        mono=Image.new('RGBA',(SIZE,SIZE))
        for kind in ['frame','screen','pane']: mono.alpha_composite(layer_image(kind,color))
        mono.save(out/f'tray-host-{mode}.ico',sizes=[(n,n) for n in [16,20,24,32]])
        for n in [16,20,24,32]:
            mono.resize((n,n),Image.Resampling.LANCZOS).save(out/f'tray-host-{mode}-{n}.png',optimize=True)

def install_windows():
    style=FAMILY['CasementHost']
    windows(style)
    source=ROOT/'windows'
    target=REPO/'WindowsHost'/'src'/'Vantage.Host.Windows'/'Assets'
    target.mkdir(parents=True,exist_ok=True)
    shutil.copy2(source/'casement-host.ico',target/'Vantage.ico')
    for src,dst in [('casement-host-balanced-1024.png','CasementHost.png'),
                    ('casement-host-light-1024.png','CasementHostLight.png'),
                    ('casement-host-dark-1024.png','CasementHostDark.png')]:
        Image.open(source/src).resize((128,128),Image.Resampling.LANCZOS).save(target/dst,optimize=True)
    shutil.copy2(source/'casement-host.ico',BRAND/'casement-host.ico')
    tray=REPO/'WindowsHost'/'src'/'Vantage.Host.Windows.Platform'/'Tray'/'Icons'
    for connected in [False,True]:
        for theme,color in [('light','#1B2430'),('dark','#F2F4F7')]:
            im=Image.new('RGBA',(SIZE,SIZE))
            for kind in ['frame','pane']: im.alpha_composite(layer_image(kind,color))
            if connected:
                arrow=Image.new('RGBA',(SIZE*4,SIZE*4))
                points=[(480,420),(524,420),(524,510),(580,510),(502,608),(424,510),(480,510)]
                ImageDraw.Draw(arrow).polygon([(x*4,y*4) for x,y in points],fill=color)
                im.alpha_composite(arrow.resize((SIZE,SIZE),Image.Resampling.LANCZOS))
            else:
                im.alpha_composite(layer_image('screen',color))
            im.save(tray/f'tray-{"connected" if connected else "idle"}-{theme}.ico',
                    sizes=[(n,n) for n in [16,20,24,32,40,48]])

def install_icon(name,destination):
    source=ROOT/(name+'.icon')
    old_names=set()
    if (destination/'icon.json').exists():
        old=json.loads((destination/'icon.json').read_text())
        old_names={layer['image-name'] for group in old['groups'] for layer in group['layers']}
    document=json.loads((source/'icon.json').read_text())
    new_names={layer['image-name'] for group in document['groups'] for layer in group['layers']}
    shutil.copytree(source,destination,dirs_exist_ok=True)
    for filename in old_names-new_names:
        (destination/'Assets'/filename).unlink(missing_ok=True)
    layers=BRAND/'layers'/FAMILY[name]['slug']
    layers.mkdir(parents=True,exist_ok=True)
    for filename in new_names: shutil.copy2(source/'Assets'/filename,layers/filename)
    obsolete=['slab.svg','slab-edge.svg','pointer.svg','pointer-edge.svg','glass-slab.png',
              'background.svg','background.png','pointer.png','small-cut-1024.png']
    for filename in obsolete: (layers/filename).unlink(missing_ok=True)

def export_native(name,rendition,output):
    subprocess.run([ICTOOL,str(ROOT/(name+'.icon')),'--export-image','--output-file',str(output),
                    '--platform','macOS','--rendition',rendition,'--width','512','--height','512',
                    '--scale','1','--design-generation','26'],check=True,capture_output=True,text=True)

def main():
    global ROOT
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--windows-only',action='store_true',help='Regenerate Windows app and tray assets without Apple tools.')
    args=parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='casement-icons-') as temp:
        ROOT=Path(temp)
        install_windows()
        if args.windows_only: return
        for name,style in FAMILY.items():
            write_icon(name,style)
            install_icon(name,REPO/('Vantage' if name=='Casement' else 'VantageHost')/(name+'.icon'))
            for dark in [False,True]:
                suffix='-dark' if dark else ''
                flat(name,style,dark).convert('RGB').save(BRAND/(style['slug']+suffix+'-1024.png'),optimize=True)
                export_native(name,'Dark' if dark else 'Default',BRAND/(style['slug']+'-mac'+suffix+'.png'))
        visionos(FAMILY['Casement'])
        stack='AppIcon.solidimagestack'
        source=ROOT/'visionos'/'Assets.xcassets'/stack
        target=REPO/'Vantage'/'Assets.xcassets'/stack
        for path in source.rglob('*'):
            if not path.is_file(): continue
            output=target/path.relative_to(source)
            output.parent.mkdir(parents=True,exist_ok=True)
            if path.suffix=='.json' and output.exists() and json.loads(path.read_text())==json.loads(output.read_text()): continue
            shutil.copy2(path,output)
        social=Image.new('RGB',(1280,640),'#F3EDF5')
        for name,x in [('casement',128),('casement-host',768)]:
            icon=Image.open(BRAND/(name+'-mac.png')).convert('RGBA').resize((384,384),Image.Resampling.LANCZOS)
            social.paste(icon,(x,64),icon)
        from PIL import ImageFont
        font=ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial Bold.ttf',42)
        draw=ImageDraw.Draw(social)
        for text,x in [('Casement',320),('Casement Host',960)]:
            draw.text((x,500),text,font=font,fill='#30283A',anchor='mt')
        social.save(BRAND/'social-preview.png',optimize=True)
    print('Updated Apple, visionOS, Windows, tray, and brand assets from one geometry source.')

if __name__=='__main__': main()
