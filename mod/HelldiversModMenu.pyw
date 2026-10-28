"""Lone Survivor menu 3.6. Gameplay directives retain their own version."""
from pathlib import Path
import json
import logging
import os
import queue
import re
import subprocess
import sys
import threading
import time
import tkinter as tk
from tkinter import ttk, messagebox
from lone_survivor import Bridge, lua_command, pause_command, DEFAULT_SETTINGS, menu_settings, NUMERIC_SETTINGS
from squadmates import ai_command, enable_ai, deploy_command, order_command, collect_telemetry, squad_settings, configure_command, dismiss_command
from squadmates_hotkeys import GameHotkeys
from squadmates_logs import Diagnostics, configure_controller_log
from gameplay_recorder import enable_command as recorder_enable, collect as collect_gameplay
from game_path import game_directory, launch_game

HERE=Path(__file__).resolve().parent
GAME=game_directory(HERE)
DEFAULTS=DEFAULT_SETTINGS.copy()
MENU_VERSION='3.6'
BG='#10151c';CARD='#18212b';TEXT='#e3e8ef';MUTED='#a4b2c2';GOLD='#f5ba13'


def switch_image(root,scale,on,disabled=False):
    """Antialiased pill switch, generated with stdlib only; no asset dependency."""
    import base64
    import struct
    import zlib
    width,height=round(46*scale),round(26*scale)
    colors=[CARD,('#536170' if disabled else GOLD) if on else '#526171',
            '#a4b2c2' if disabled else ('#10151c' if on else '#ffffff')]
    colors=[tuple(bytes.fromhex(c[1:])) for c in colors]
    pixels=bytearray()
    for y in range(height):
        pixels.append(0)
        for x in range(width):
            samples=[]
            for dy in (.125,.375,.625,.875):
                for dx in (.125,.375,.625,.875):
                    px,py=(x+dx)/scale,(y+dy)/scale
                    cx=min(33,max(13,px))
                    track=(px-cx)**2+(py-13)**2<=11**2
                    knob=(px-(33 if on else 13))**2+(py-13)**2<=8**2
                    samples.append(colors[2 if knob else 1 if track else 0])
            pixels.extend(round(sum(c[i] for c in samples)/16) for i in range(3))
    def chunk(kind,data):
        return struct.pack('!I',len(data))+kind+data+struct.pack('!I',zlib.crc32(kind+data))
    png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('!2I5B',width,height,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(bytes(pixels)))+chunk(b'IEND',b'')
    return tk.PhotoImage(master=root,data=base64.b64encode(png))


def enable_dpi_awareness():
    if os.name!='nt':return
    import ctypes
    try:
        ctypes.windll.user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))
    except (AttributeError,OSError):
        try:ctypes.windll.shcore.SetProcessDpiAwareness(1)
        except (AttributeError,OSError):pass


def set_launcher_app_id():
    if os.name!='nt':return
    import ctypes
    try:
        ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID('Helldivers.LoneSurvivor.ModMenu')
    except (AttributeError,OSError):pass


def set_launcher_icon(root):
    icon=HERE/'HelldiversModMenu.ico'
    if icon.is_file():
        try:root.iconbitmap(default=str(icon))
        except tk.TclError:pass


def work_area(root):
    if os.name=='nt':
        import ctypes
        from ctypes import wintypes
        rect=wintypes.RECT()
        if ctypes.windll.user32.SystemParametersInfoW(0x30,0,ctypes.byref(rect),0):
            return rect.left,rect.top,rect.right-rect.left,rect.bottom-rect.top
    return 0,0,root.winfo_screenwidth(),root.winfo_screenheight()


def squad_version():
    try:
        match=re.search(r"revision='([^']+)'",(HERE/'ai_squadmates.lua').read_text(encoding='utf-8'))
        return match[1] if match else 'unknown'
    except OSError:return 'unknown'


class ScrollPane(ttk.Frame):
    def __init__(self,parent):
        super().__init__(parent)
        self.rowconfigure(0,weight=1);self.columnconfigure(0,weight=1)
        self.canvas=tk.Canvas(self,bg=BG,highlightthickness=0,bd=0,yscrollincrement=22)
        self.bar=ttk.Scrollbar(self,orient='vertical',command=self.canvas.yview)
        self.canvas.configure(yscrollcommand=self.bar.set)
        self.canvas.grid(row=0,column=0,sticky='nsew');self.bar.grid(row=0,column=1,sticky='ns')
        self.content=ttk.Frame(self.canvas,padding=(4,6,8,12))
        self.content.columnconfigure(0,weight=1)
        self.window=self.canvas.create_window(0,0,window=self.content,anchor='nw')
        self.canvas.bind('<Configure>',self.resize)
        self.content.bind('<Configure>',lambda e:self.canvas.configure(scrollregion=self.canvas.bbox('all')))

    def resize(self,event):
        self.canvas.itemconfigure(self.window,width=event.width)
        self.canvas.configure(scrollregion=self.canvas.bbox('all'))


class NumberSlider(tk.Canvas):
    """Responsive numbered track; mouse, arrows and Home/End snap to valid steps."""
    def __init__(self,parent,variable,enabled,step,scale,command):
        super().__init__(parent,width=round(240*scale),height=round(55*scale),bg=CARD,
                         bd=0,highlightthickness=1,highlightbackground=CARD,
                         highlightcolor=GOLD,takefocus=True,cursor='hand2')
        self.variable=variable;self.enabled=enabled;self.step=step;self.scale=scale;self.command=command
        self.bind('<Configure>',self.draw)
        self.bind('<Button-1>',self.pick);self.bind('<B1-Motion>',self.pick)
        for key,delta in [('Left',-step),('Down',-step),('Right',step),('Up',step),('Prior',1),('Next',-1)]:
            self.bind('<'+key+'>',lambda e,d=delta:self.set_value(self.variable.get()+d))
        self.bind('<Home>',lambda e:self.set_value(1));self.bind('<End>',lambda e:self.set_value(10))
        self._traces=[(variable,variable.trace_add('write',self.draw)),(enabled,enabled.trace_add('write',self.draw))]
        self.bind('<Destroy>',self.cleanup)

    def cleanup(self,event):
        if event.widget is self:
            for variable,trace in self._traces:variable.trace_remove('write',trace)

    def set_value(self,value):
        value=max(1,min(10,round((value-1)/self.step)*self.step+1))
        if value!=self.variable.get():self.variable.set(value);self.command()
        return 'break'

    def pick(self,event):
        self.focus_set();margin=round(15*self.scale)
        return self.set_value(1+9*(event.x-margin)/max(1,self.winfo_width()-2*margin))

    def draw(self,*args):
        self.delete('all');scale=self.scale;margin=round(15*scale)
        left,right=margin,max(margin+1,self.winfo_width()-margin);y=round(15*scale)
        color=GOLD if self.enabled.get() else '#7f8b99'
        selected=left+(right-left)*(self.variable.get()-1)/9
        self.create_line(left,y,right,y,fill='#526171',width=round(3*scale))
        self.create_line(left,y,selected,y,fill=color,width=round(3*scale))
        for value in range(1,11):
            x=left+(right-left)*(value-1)/9
            self.create_line(x,y-4*scale,x,y+4*scale,fill=MUTED,width=max(1,round(scale)))
            self.create_text(x,36*scale,text=str(value),fill=MUTED,font=('Segoe UI',9))
        radius=7*scale
        self.create_oval(selected-radius,y-radius,selected+radius,y+radius,fill=color,outline=CARD,width=2)


class App:
    def __init__(self,root,*,start_worker=True):
        self.root=root;self.controller_enabled=start_worker
        self.events=queue.Queue();self.commands=queue.Queue();self.closed=False;self.closing=False
        self.last_status=None;self.ai_ready=False;self._settings_job=None
        self.bridge=Bridge(GAME) if start_worker else None
        self.hotkeys=GameHotkeys() if start_worker else None
        self.diagnostics=Diagnostics(GAME) if start_worker else None
        self.scale=max(1,root.winfo_fpixels('1i')/96)
        root.title('HELLDIVERS | LONE SURVIVOR | Menu '+MENU_VERSION)
        set_launcher_icon(root)
        root.configure(background=BG);root.resizable(True,True)
        left,top,width,height=work_area(root)
        w=min(round(1040*self.scale),max(320,width-64));h=min(round(760*self.scale),max(300,height-80))
        root.geometry(f'{w}x{h}+{left+(width-w)//2}+{top+(height-h)//2}')
        root.minsize(min(w,round(480*self.scale)),min(h,round(460*self.scale)))
        try:
            saved=json.loads((HERE/'LoneSurvivor.settings.json').read_text())
            settings=menu_settings(saved)
        except (OSError,ValueError,TypeError):saved={};settings=DEFAULTS.copy()
        squad_options=squad_settings(saved)
        self.squad_auto=tk.BooleanVar(value=squad_options['squad_auto_deploy'])
        self.squad_target=tk.StringVar(value=str(squad_options['squad_target_count']))
        self._last_squad_target=squad_options['squad_target_count']
        self.vars={k:tk.BooleanVar(value=settings[k]) for k in DEFAULTS if k not in NUMERIC_SETTINGS}
        self.numbers={k:(tk.DoubleVar if step!=1 else tk.IntVar)(value=settings[k]) for k,(default,step) in NUMERIC_SETTINGS.items()}
        self.multiplier=self.numbers['multiplier']
        self.sliders={};self.slider_toggles={};self.slider_titles={}
        self.auto=tk.BooleanVar(value=True)
        self.status=tk.StringVar(value='Looking for HELLDIVERS...')
        self.ai_status=tk.StringVar(value='No squad connected. Enter a solo mission and deploy with F6.')
        self._style();self._build_ui()
        self.write_log('Menu '+MENU_VERSION+' ready. Live game results appear here.')
        self.write_log('Keep the menu open while playing. Closing restores normal directives.')
        if self.diagnostics:self.write_log('Detailed gameplay logs: '+str(self.diagnostics.journal.directory))
        root.bind('<F1>',lambda e:self.apply(True));root.bind('<MouseWheel>',self._wheel,add='+')
        root.protocol('WM_DELETE_WINDOW',self.on_close)
        if start_worker:
            threading.Thread(target=self.worker,daemon=True).start()
            self.changed();root.after(150,self.poll);root.after(40,self.poll_hotkeys)

    def _style(self):
        style=ttk.Style(self.root);style.theme_use('clam')
        style.configure('.',font=('Segoe UI',10),foreground=TEXT,background=BG)
        style.configure('TFrame',background=BG)
        style.configure('Card.TFrame',background=CARD)
        style.configure('TLabel',background=BG,foreground=TEXT)
        style.configure('Card.TLabel',background=CARD,foreground=TEXT)
        style.configure('Muted.TLabel',background=BG,foreground=MUTED)
        style.configure('Muted.Card.TLabel',background=CARD,foreground=MUTED)
        style.configure('Section.Card.TLabel',background=CARD,foreground=GOLD,font=('Segoe UI',11,'bold'))
        self._switch_images=[switch_image(self.root,self.scale,on,disabled) for disabled,on in [(False,False),(False,True),(True,False),(True,True)]]
        style.element_create('Switch.indicator','image',self._switch_images[0],
                             ('disabled','selected',self._switch_images[3]),
                             ('disabled',self._switch_images[2]),('selected',self._switch_images[1]))
        style.layout('TCheckbutton',[('Checkbutton.padding',{'sticky':'nswe','children':[
            ('Switch.indicator',{'side':'right','sticky':'e'}),
            ('Checkbutton.focus',{'side':'left','sticky':'nswe','children':[
                ('Checkbutton.label',{'sticky':'nswe'})]})]})])
        style.configure('TCheckbutton',background=CARD,foreground=TEXT,padding=(0,4),font=('Segoe UI',10,'bold'),focuscolor=GOLD)
        style.map('TCheckbutton',background=[('active',CARD)],foreground=[('disabled',MUTED),('active','#ffffff')])
        style.configure('TButton',padding=(16,10),background='#273544',foreground=TEXT,borderwidth=0,relief='flat',focuscolor=GOLD)
        style.map('TButton',background=[('active','#35485c'),('pressed','#425a70')],foreground=[('disabled','#7f8b99')])
        style.configure('Accent.TButton',background=GOLD,foreground=BG,font=('Segoe UI',10,'bold'))
        style.map('Accent.TButton',background=[('active','#ffd15c'),('pressed','#dca50a')],foreground=[('disabled','#6b5a2b')])
        style.layout('TNotebook',[])
        style.layout('TNotebook.Tab',[('Notebook.padding',{'sticky':'nswe','children':[
            ('Notebook.focus',{'sticky':'nswe','children':[('Notebook.label',{'sticky':'nswe'})]})]})])
        style.configure('TNotebook',background=BG,borderwidth=0,lightcolor=BG,darkcolor=BG,tabmargins=(0,0,0,10))
        style.configure('TNotebook.Tab',background='#202c38',foreground=MUTED,padding=(22,11),borderwidth=0,lightcolor=BG,darkcolor=BG)
        style.map('TNotebook.Tab',background=[('selected',GOLD),('active','#314252')],foreground=[('selected',GOLD),('active',TEXT)])
        style.configure('TCombobox',fieldbackground='#101821',background='#273544',foreground=TEXT,arrowcolor=TEXT,padding=8,borderwidth=0,lightcolor='#273544',darkcolor='#273544',bordercolor='#273544')
        style.map('TCombobox',fieldbackground=[('readonly','#101821')],foreground=[('readonly',TEXT)])
        style.configure('TSpinbox',fieldbackground='#101821',background='#273544',foreground=TEXT,
                        arrowcolor=TEXT,insertcolor=TEXT,padding=(6,5),arrowsize=14,
                        selectbackground=GOLD,selectforeground=BG,borderwidth=1,
                        lightcolor='#34465a',darkcolor='#34465a',bordercolor='#34465a')
        style.map('TSpinbox',foreground=[('disabled',MUTED)],fieldbackground=[('disabled',CARD)])
        style.layout('Vertical.TScrollbar',[('Vertical.Scrollbar.trough',{'sticky':'ns','children':[
            ('Vertical.Scrollbar.thumb',{'expand':'1','sticky':'nswe'})]})])
        style.configure('Vertical.TScrollbar',background='#34465a',troughcolor=BG,borderwidth=0,arrowsize=10,lightcolor='#34465a',darkcolor='#34465a')
        self.root.option_add('*TCombobox*Listbox.background',CARD)
        self.root.option_add('*TCombobox*Listbox.foreground',TEXT)

    def label(self,parent,text=None,*,variable=None,style='Card.TLabel',font=None):
        label=ttk.Label(parent,text=text,textvariable=variable,style=style,wraplength=round(640*self.scale),justify='left',font=font)
        def wrap(event):
            width=max(80,event.width-2)
            if abs(float(label.cget('wraplength'))-width)>2:label.configure(wraplength=width)
        label.bind('<Configure>',wrap)
        return label

    def card(self,parent,title):
        card=ttk.Frame(parent,style='Card.TFrame',padding=16);card.columnconfigure(0,weight=1)
        self.label(card,title,style='Section.Card.TLabel').grid(row=0,column=0,sticky='ew',pady=(0,8))
        return card

    def flow(self,parent,widgets,*,max_columns=2,min_column=360,span_last=False):
        def layout(event):
            cols=max(1,min(max_columns,int(event.width/(min_column*self.scale))))
            if getattr(parent,'_flow_cols',None)==cols:return
            parent._flow_cols=cols
            for col in range(max_columns):parent.columnconfigure(col,weight=1 if col<cols else 0,uniform='flow' if col<cols else '')
            for i,widget in enumerate(widgets):
                span=cols if span_last and i==len(widgets)-1 and i%cols==0 else 1
                widget.grid(row=i//cols,column=i%cols,columnspan=span,sticky='nsew',padx=(0,8 if cols>1 and i%cols==0 and span==1 else 0),pady=(0,8))
        parent.bind('<Configure>',layout)
        layout(type('Size',(),{'width':round(900*self.scale)})())

    def option(self,card,row,key,title,description):
        ttk.Checkbutton(card,text=title,variable=self.vars[key],command=self.changed).grid(row=row,column=0,sticky='ew',pady=(4,0))
        self.label(card,description,style='Muted.Card.TLabel').grid(row=row+1,column=0,sticky='ew',pady=(0,10))

    def slider_option(self,card,row,key,number,title,description,suffix=''):
        label=tk.StringVar()
        def update_title(*args):label.set(title+': '+format(self.numbers[number].get(),'g')+suffix)
        update_title();self.numbers[number].trace_add('write',update_title)
        self.slider_titles[number]=label
        toggle=ttk.Checkbutton(card,textvariable=label,variable=self.vars[key],command=self.changed)
        toggle.grid(row=row,column=0,sticky='ew',pady=(4,0));self.slider_toggles[number]=toggle
        self.label(card,description,style='Muted.Card.TLabel').grid(row=row+1,column=0,sticky='ew')
        slider=NumberSlider(card,self.numbers[number],self.vars[key],NUMERIC_SETTINGS[number][1],self.scale,self.changed)
        slider.grid(row=row+2,column=0,sticky='ew',pady=(3,8));self.sliders[number]=slider

    def _build_ui(self):
        self.root.columnconfigure(0,weight=1);self.root.rowconfigure(1,weight=1)
        header=ttk.Frame(self.root,padding=(20,14,20,10));header.grid(row=0,column=0,sticky='ew');header.columnconfigure(0,weight=1)
        ttk.Label(header,text='HELLDIVERS / DIVE HARDER',foreground=MUTED,font=('Segoe UI',9,'bold')).grid(row=0,column=0,sticky='w')
        ttk.Label(header,text='LONE SURVIVOR',foreground=GOLD,font=('Segoe UI',22,'bold')).grid(row=1,column=0,sticky='w',pady=(0,2))
        self.label(header,f'MENU {MENU_VERSION}   /   DIRECTIVES 2.1   /   SQUAD {squad_version()}',style='Muted.TLabel').grid(row=2,column=0,sticky='ew')
        self.connection=self.label(header,variable=self.status,style='TLabel',font=('Segoe UI',10,'bold'))
        self.connection.grid(row=3,column=0,sticky='ew',pady=(10,0))
        self.tabs=ttk.Notebook(self.root);self.tabs.grid(row=1,column=0,sticky='nsew',padx=16)
        self.directives=ScrollPane(self.tabs);self.squad=ScrollPane(self.tabs)
        activity=ttk.Frame(self.tabs,padding=(4,6,4,8));activity.columnconfigure(0,weight=1);activity.rowconfigure(1,weight=1)
        self.tabs.add(self.directives,text='Directives');self.tabs.add(self.squad,text='Squad');self.tabs.add(activity,text='Activity')
        group=ttk.Frame(self.directives.content);group.grid(row=0,column=0,sticky='ew')
        left=ttk.Frame(group);left.columnconfigure(0,weight=1)
        weapons=self.card(left,'Stratagems & weapons');weapons.grid(row=0,column=0,sticky='ew',pady=(0,8))
        self.option(weapons,1,'stratagems','Unlimited stratagems','Zero cooldown and unlimited uses. Original orbital delivery timing.')
        self.option(weapons,3,'autoreload','Automatic reload','Reload an empty magazine using normal animations and spare ammunition.')
        survival=self.card(group,'Player survival')
        self.option(survival,1,'stamina','Fast stamina recovery','5x recovery while resting. Sprint still uses stamina.')
        self.slider_option(survival,3,'playerhealth','health_multiplier','Player health','Health for your original Helldiver. A controlled bot keeps its own condition.','×')
        self.slider_option(survival,6,'playerrespawns','respawn_count','Respawns','Finite solo respawns; normal consumption. Objectives restore one up to this count.')
        self.slider_option(survival,9,'playergrenades','grenade_count','Grenades','Grenades for your original Helldiver on spawn and resupply; normal consumption.')
        rewards=self.card(left,'Mission rewards & apply');rewards.grid(row=1,column=0,sticky='ew')
        self.slider_option(rewards,1,'rewards','multiplier','Earned XP and research','Multiplier at mission payout. 1× is normal; no free currency.','×')
        ttk.Checkbutton(rewards,text='Apply automatically',variable=self.auto,command=self.changed).grid(row=4,column=0,sticky='ew')
        self.label(rewards,'Selected settings are applied when HELLDIVERS is ready.',style='Muted.Card.TLabel').grid(row=5,column=0,sticky='ew')
        self.flow(group,[left,survival])
        squad_cards=ttk.Frame(self.squad.content);squad_cards.grid(row=0,column=0,sticky='ew')
        actions=self.card(squad_cards,'Squad controls')
        action_grid=ttk.Frame(actions,style='Card.TFrame');action_grid.grid(row=1,column=0,sticky='ew')
        self.squad_buttons=[]
        for text,command in [('Deploy bot / F6','deploy_bot'),('Dismiss bots / F7','dismiss_bot'),('Recall everyone','recall_all'),('Next bot / F9','switch_bot'),('First Helldiver / hold F9','home_player'),('Original Helldiver / F11','original_player')]:
            button=ttk.Button(action_grid,text=text,command=lambda c=command:self.queue_action(c))
            self.squad_buttons.append(button)
        self.flow(action_grid,self.squad_buttons,min_column=205)
        self.label(actions,'Tap F6: add one bot. Tap F7: dismiss all bots. New bots use random unlocked equipment.',style='Muted.Card.TLabel').grid(row=2,column=0,sticky='ew',pady=(6,0))
        deployment=ttk.Frame(actions,style='Card.TFrame');deployment.grid(row=3,column=0,sticky='ew',pady=(8,0))
        auto_deploy=ttk.Checkbutton(deployment,text='Auto deploy bots',variable=self.squad_auto,command=self.changed)
        minimum=ttk.Frame(deployment,style='Card.TFrame')
        self.label(minimum,'Minimum:',style='Muted.Card.TLabel').pack(side='left',padx=(0,4))
        target=ttk.Spinbox(minimum,from_=1,to=2147483647,textvariable=self.squad_target,width=7,command=self.changed)
        target.pack(side='left');target.bind('<Return>',lambda e:self.changed());target.bind('<FocusOut>',lambda e:self.changed())
        self.flow(deployment,[auto_deploy,minimum],min_column=205)
        self.label(actions,'Hold F6 for 0.7 s: maintain this minimum. Hold F7: stop auto deployment and keep current bots. Default OFF; starts after you deploy. Tap F7 also pauses it until hold F6, toggle off/on or the next mission. Tap F6 can exceed the minimum.',style='Muted.Card.TLabel').grid(row=4,column=0,sticky='ew',pady=(5,0))
        orders=self.card(squad_cards,'Orders in game')
        for row,(title,description) in enumerate([
            ('F8 tap / move or work','Aim at a position and tap F8. Bots cycle in order; new commands replace old ones. Near a supported terminal, the bot operates it.'),
            ('F8 hold / recall all','Hold for 0.7 seconds to cancel orders and bring everyone back.'),
            ('F9 tap / next bot','Cycle through standing bots anywhere in the mission. The body you leave joins the AI squad. Your stratagems follow you.'),
            ('F9 hold / first Helldiver','Hold for 0.7 seconds to return to your first Helldiver if alive, including while downed. No respawn point spent.'),
            ('Death takeover / free','Take an eligible standing bot anywhere in the mission, or a living downed bot if none are standing. Keep your stratagems and its current gear, ammo and health.'),
            ('F11 / original Helldiver','Return free if your first Helldiver is alive. Otherwise request a replacement for one respawn point and keep playing until it arrives.')]):
            self.label(orders,title,font=('Segoe UI',10,'bold')).grid(row=1+row*2,column=0,sticky='ew',pady=(4,0))
            self.label(orders,description,style='Muted.Card.TLabel').grid(row=2+row*2,column=0,sticky='ew',pady=(2,10))
        self.label(actions,'Live squad',style='Section.Card.TLabel').grid(row=5,column=0,sticky='ew',pady=(18,6))
        self.label(actions,variable=self.ai_status).grid(row=6,column=0,sticky='ew')
        self.label(actions,'Solo missions only. Full diagnostics are saved beside the menu.',style='Muted.Card.TLabel').grid(row=7,column=0,sticky='ew',pady=(10,0))
        self.flow(squad_cards,[actions,orders])
        logbar=ttk.Frame(activity);logbar.grid(row=0,column=0,sticky='ew',pady=(0,8));logbar.columnconfigure(0,weight=1)
        ttk.Label(logbar,text='Verification & activity',foreground=GOLD,font=('Segoe UI',10,'bold')).grid(row=0,column=0,sticky='w')
        ttk.Button(logbar,text='Copy',command=self.copy_log).grid(row=0,column=1,padx=(4,0))
        ttk.Button(logbar,text='Clear view',command=self.clear_log).grid(row=0,column=2,padx=(6,0))
        logbox=ttk.Frame(activity);logbox.grid(row=1,column=0,sticky='nsew');logbox.columnconfigure(0,weight=1);logbox.rowconfigure(0,weight=1)
        self.log=tk.Text(logbox,bg='#090e14',fg='#bce7e5',insertbackground=TEXT,font=('Consolas',10),relief='flat',wrap='word',height=10,width=1,state='disabled',padx=12,pady=10,highlightthickness=1,highlightbackground='#283748')
        logscroll=ttk.Scrollbar(logbox,orient='vertical',command=self.log.yview);self.log.configure(yscrollcommand=logscroll.set)
        self.log.grid(row=0,column=0,sticky='nsew');logscroll.grid(row=0,column=1,sticky='ns')
        footer=ttk.Frame(self.root,padding=(20,10,20,10));footer.grid(row=2,column=0,sticky='ew');footer.columnconfigure(0,weight=1)
        self.action_bar=ttk.Frame(footer);self.action_bar.grid(row=0,column=0,sticky='ew')
        self.primary_buttons=[ttk.Button(self.action_bar,text='Launch game',command=self.launch),
                              ttk.Button(self.action_bar,text='Apply & verify / F1',style='Accent.TButton',command=lambda:self.apply(True)),
                              ttk.Button(self.action_bar,text='Restore normal',command=self.restore)]
        self.flow(self.action_bar,self.primary_buttons,max_columns=3,min_column=205,span_last=True)
        self.label(footer,'Keep this menu open while playing. Restart it after installing updates.',style='Muted.TLabel').grid(row=1,column=0,sticky='ew')

    def _wheel(self,event):
        widget=event.widget
        while widget is not None:
            if isinstance(widget,(tk.Text,ttk.Combobox)):return
            for pane in (self.directives,self.squad):
                if widget in (pane.content,pane.canvas):
                    if pane.canvas.bbox('all') and pane.content.winfo_height()>pane.canvas.winfo_height():
                        pane.canvas.yview_scroll(-int(event.delta/120 or (1 if event.delta>0 else -1))*3,'units')
                    return 'break'
            widget=getattr(widget,'master',None)

    def write_log(self,message):
        try:logging.info(message)
        except OSError:pass  # A locked log file must not stop the Tk event pump.
        follow=self.log.yview()[1]>.98
        self.log.configure(state='normal');self.log.insert('end',time.strftime('[%H:%M:%S] ')+message+'\n')
        lines=int(self.log.index('end-1c').split('.')[0])
        if lines>2500:self.log.delete('1.0',str(lines-2500)+'.0')
        if follow:self.log.see('end')
        self.log.configure(state='disabled')

    def clear_log(self):
        self.log.configure(state='normal');self.log.delete('1.0','end');self.log.configure(state='disabled')

    def copy_log(self):
        self.root.clipboard_clear();self.root.clipboard_append(self.log.get('1.0','end-1c'))

    def settings(self):
        try:
            target=int(self.squad_target.get())
            if target<1:raise ValueError('positive count required')
            self._last_squad_target=target
        except ValueError:
            target=self._last_squad_target;self.squad_target.set(str(target))
        return {**{k:v.get() for k,v in self.vars.items()},**{k:v.get() for k,v in self.numbers.items()},
                'squad_auto_deploy':self.squad_auto.get(),'squad_target_count':target}

    def changed(self):
        if not self.controller_enabled or self.closing:return
        if self._settings_job:self.root.after_cancel(self._settings_job)
        self._settings_job=self.root.after(180,self._commit_settings)

    def _commit_settings(self):
        self._settings_job=None;settings=self.settings()
        try:(HERE/'LoneSurvivor.settings.json').write_text(json.dumps(settings,indent=2))
        except OSError:pass
        self.commands.put(('settings',(settings,self.auto.get())))

    def apply(self,manual=False):
        if self.closing:return
        self.status.set('Apply queued. Waiting for the game...')
        self.commands.put(('apply',(self.settings(),manual)))

    def queue_action(self,command):
        if self.closing:return
        if command in ('auto_deploy_on','auto_deploy_off'):
            self.squad_auto.set(command=='auto_deploy_on')
            if self._settings_job:self.root.after_cancel(self._settings_job)
            self._commit_settings()
            self.ai_status.set('Auto deployment '+('enabled' if self.squad_auto.get() else 'stopped')+'. Sending command...')
            self.commands.put((command,self.settings()))
            return
        self.ai_status.set('Sending command: '+{'deploy_bot':'deploy bot','dismiss_bot':'dismiss bots','guard_bot':'order at cursor','recall_bot':'recall bot','recall_all':'recall everyone','switch_bot':'next bot','home_player':'first Helldiver','original_player':'return original Helldiver'}[command])
        self.commands.put((command,None))

    def restore(self):
        if self.closing:return
        self.squad_auto.set(False)
        for v in self.vars.values():v.set(False)
        self.commands.put(('dismiss_bot',None));self.changed();self.apply(True)

    def poll_hotkeys(self):
        if self.closed or self.closing:return
        for command in self.hotkeys.poll(self.bridge.pid):self.queue_action(command)
        self.root.after(40,self.poll_hotkeys)

    def launch(self):
        if self.closing:return
        self.status.set('Launch requested...');self.commands.put(('launch',None))


    def worker(self):
        settings=DEFAULTS.copy();auto=True;pending=False;manual=False;applied=None;last_pid=None;last_error=None;recorder_pid=None
        pause_pid=None;squad_applied=None;pause_status=None
        while not self.closed:
            try:
                try:
                    command,payload=self.commands.get(timeout=1)
                    if command=='close':
                        try:
                            if self.bridge.running():
                                try:
                                    self.bridge.execute(ai_command(False))
                                    collect_telemetry(self.bridge,self.diagnostics,drain=True)
                                finally:
                                    try:collect_gameplay(self.bridge,self.diagnostics,stop=True)
                                    finally:self.bridge.execute(lua_command(dict(stratagems=False,autoreload=False,stamina=False,multiplier=1),offline_pause=False))
                        except Exception as e:
                            try:self.diagnostics.error('close_error',e)
                            except OSError:pass
                            self.events.put(('log','Cleanup error: '+str(e)))
                        finally:
                            try:self.diagnostics.close()
                            finally:self.events.put(('closed',None));self.bridge.disconnect()
                        return
                    if command=='launch':
                        if self.bridge.running():self.events.put(('log','Game is already running.'))
                        else:
                            launch_game()
                            self.events.put(('log','HELLDIVERS launch requested.'))
                        continue
                    if command in ('auto_deploy_on','auto_deploy_off'):
                        settings=payload
                    if command in ('deploy_bot','dismiss_bot','guard_bot','recall_bot','recall_all','original_player','switch_bot','home_player','auto_deploy_on','auto_deploy_off'):
                        self.diagnostics.write('events',{'kind':'controller_command','data':{'command':command}})
                        if not self.bridge.attach():raise RuntimeError('Launch HELLDIVERS before deploying a bot.')
                        if self.bridge.pid!=last_pid:
                            self.ai_ready=False;applied=None;pending=auto or manual;last_pid=self.bridge.pid
                        if command in ('auto_deploy_on','auto_deploy_off'):
                            options=squad_settings(settings)
                            if command=='auto_deploy_on' and not self.ai_ready:
                                enable_ai(self.bridge,auto_deploy=True,target_count=options['squad_target_count']);self.ai_ready=True
                            reply=self.bridge.execute(configure_command(options,resume=command=='auto_deploy_on'))
                            squad_applied=options
                        elif command=='deploy_bot':
                            options=squad_settings(settings)
                            enable_ai(self.bridge,auto_deploy=options['squad_auto_deploy'],target_count=options['squad_target_count']);self.ai_ready=True
                            reply=self.bridge.execute(deploy_command())
                        elif command=='dismiss_bot':
                            reply=self.bridge.execute(dismiss_command())
                            collect_telemetry(self.bridge,self.diagnostics,drain=True)
                        elif command in ('original_player','switch_bot','home_player') and not self.ai_ready:
                            options=squad_settings(settings)
                            enable_ai(self.bridge,auto_deploy=options['squad_auto_deploy'],target_count=options['squad_target_count']);self.ai_ready=True
                            reply=self.bridge.execute(order_command(command))
                        else:
                            reply=self.bridge.execute(order_command(command))
                        self.events.put(('ai',reply));self.events.put(('log',reply))
                    if command=='settings':settings,auto=payload;pending=auto
                    if command=='apply':settings,manual=payload;pending=True
                except queue.Empty:pass
                if not self.bridge.attach():
                    if last_pid:self.diagnostics.record_native_crash(last_pid)
                    self.events.put(('status','Game not running. Launch HELLDIVERS to connect.'));applied=None;last_pid=None;self.ai_ready=False;recorder_pid=None
                    continue
                if last_pid!=self.bridge.pid:
                    if last_pid is not None:self.ai_ready=False
                    last_pid=self.bridge.pid;applied=None;pending=auto or manual
                    self.events.put(('log',f'Connected to helldivers.exe (PID {last_pid}), x64 build verified.'))
                if pause_pid!=self.bridge.pid:
                    reply=self.bridge.execute(pause_command());pause_pid=self.bridge.pid
                    self.events.put(('log',reply))
                else:
                    reply=self.bridge.execute('local p=rawget(_G,"HelldiversOfflinePause");if not p then return "MISSING" end;p.sync();return "Offline pause "..p.revision..": "..tostring(p.status)')
                    if reply=='MISSING':pause_pid=None
                    elif reply!=pause_status:pause_status=reply;self.events.put(('log',reply))
                options=squad_settings(settings)
                if options['squad_auto_deploy'] and not self.ai_ready:
                    enable_ai(self.bridge,auto_deploy=True,target_count=options['squad_target_count']);self.ai_ready=True;squad_applied=options
                elif self.ai_ready and options!=squad_applied:
                    self.events.put(('ai',self.bridge.execute(configure_command(options))));squad_applied=options
                if pending and (manual or settings!=applied):
                    result=self.bridge.execute(lua_command(settings))
                    if not result.startswith('VERIFIED v2.1'):raise RuntimeError('Game did not verify the directives: '+result)
                    applied=settings.copy();pending=False;manual=False;last_error=None
                    self.events.put(('log',result));self.events.put(('status','Verified by game. Selected directives are active.'))
                elif applied:
                    reply=self.bridge.execute('local m=rawget(_G,"LoneSurvivorV2"); return m and m.status() or "MISSING"')
                    if not reply.startswith('VERIFIED v2.1'):applied=None;pending=auto
                    elif reply!=self.last_status:self.last_status=reply;self.events.put(('detail',reply))
                else:self.events.put(('status','Connected. Click Apply & verify to activate.'))
                if self.ai_ready:
                    self.events.put(('ai',collect_telemetry(self.bridge,self.diagnostics)))
                # Independent of bot deployment and gameplay option selections.
                if recorder_pid!=self.bridge.pid:
                    result=self.bridge.execute(recorder_enable())
                    if not result.startswith('Gameplay recorder '):raise RuntimeError(result)
                    recorder_pid=self.bridge.pid;self.events.put(('log',result))
                collect_gameplay(self.bridge,self.diagnostics)
            except Exception as e:
                try:
                    self.diagnostics.error('controller_error',e)
                    if not self.bridge.running():self.diagnostics.record_native_crash(self.bridge.pid or last_pid)
                except OSError:pass
                message=str(e);self.events.put(('status','Not applied: '+message))
                if message!=last_error:self.events.put(('log','ERROR: '+message));last_error=message
                # Auto retries allow scripts to finish loading; no fabricated success.
                manual=False;time.sleep(1)
    def poll(self):
        if self.closed:return
        latest={};logs=[]
        try:
            for _ in range(80):
                kind,value=self.events.get_nowait()
                if kind=='closed':self.closed=True;self.root.destroy();return
                if kind=='status':latest['status']=value
                if kind=='log':logs.append(value)
                if kind=='detail' and value!=getattr(self,'detail',None):
                    self.detail=value
                    lines=value.splitlines()
                    latest['status']='Verified by game | '+(lines[1] if len(lines)>1 else lines[0])
                if kind=='ai':latest['ai']=value
        except queue.Empty:pass
        if logs:self.write_log('\n'.join(logs))
        if 'status' in latest and not self.closing:
            message=latest['status'].splitlines()[0]
            self.status.set(message[:180]+('...' if len(message)>180 else ''))
        if 'ai' in latest:self.ai_status.set(latest['ai'])
        self.root.after(40 if not self.events.empty() else 120,self.poll)
    def on_close(self):
        if self.closing:return
        self.closing=True
        if self._settings_job:
            self.root.after_cancel(self._settings_job);self._settings_job=None
            if self.controller_enabled:self._commit_settings()
        if not self.controller_enabled:
            self.closed=True;self.root.destroy();return
        self.status.set('Restoring normal directives...')
        for button in self.primary_buttons+self.squad_buttons:button.state(['disabled'])
        try:
            while True:self.commands.get_nowait()
        except queue.Empty:pass
        self.commands.put(('close',None))
        self.root.after(10000,self.finish_close)
    def finish_close(self):
        if not self.closed:self.closed=True;self.root.destroy()

if __name__=='__main__':
    configure_controller_log(GAME)
    try:
        enable_dpi_awareness()
        set_launcher_app_id()
        root=tk.Tk();app=App(root);root.mainloop()
    except Exception:
        logging.exception('Mod menu failed')
        messagebox.showerror('Lone Survivor error','The mod menu could not start. See LoneSurvivor.log beside the script.')

