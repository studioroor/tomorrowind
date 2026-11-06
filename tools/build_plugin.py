"""Builds Tomorrowind.esp: worker NPCs, tools, building activators.

Usage: python3 tools/build_plugin.py "<Morrowind Data Files dir>"
Writes Tomorrowind.esp into the repo root.
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(__file__))
import tes3  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Tools are one-handed on purpose: in the one-handed attack animation the
# "Chop Hit" key (where damage happens) sits in a gap between "Chop Min Hit"
# and "Chop Large Follow Start", so workers can swing without ever hitting.
# Damage is zero anyway.
TOOLS = [
    # id, name, model, icon, weapon type (7 = axe 1h, 3 = blunt 1h)
    ('tmw_tool_pick', "Colony Pick", r'w\W_miner_pick.nif', r'w\tx_miner_pick.tga', 7),
    ('tmw_tool_hoe', "Colony Hoe", r'w\W_miner_pick.nif', r'w\tx_miner_pick.tga', 7),
    ('tmw_tool_axe', "Colony Axe", r'w\W_WARAXE_IRON.nif', r'w\Tx_waraxe_iron.tga', 7),
    ('tmw_tool_hammer', "Colony Mallet", r'w\W_CLUB_IRON.nif', r'w\Tx_club_iron.tga', 3),
]

ACTIVATORS = [
    ('tmw_storehouse', 'Colony Storehouse', r'x\ex_de_shack_02.nif'),
    ('tmw_lumber', "Woodcutter's Camp", r'f\furn_log_01.nif'),
    ('tmw_farm', 'Saltrice Paddy', r'o\flora_saltrice_02.nif'),
    ('tmw_mine', 'Ore Vein', r'o\contain_rock_ebony_01.nif'),
    ('tmw_smelter', 'Smelter', r'f\furn_de_forge_01.nif'),
    ('tmw_house', 'Hlaalu House', r'x\ex_hlaalu_b_01.nif'),
    ('tmw_construction', 'Construction Site', r'x\ex_de_scaffold_01.nif'),
]

STATICS = [
    ('tmw_decor_saltrice', r'o\flora_saltrice_01.nif'),
]

# id, name, female, head, hair
WORKERS = [
    ('tmw_worker_01', 'Dravil Aryon', False, 'b_n_dark elf_m_head_02', 'b_n_dark elf_m_hair_03'),
    ('tmw_worker_02', 'Ilvi Sadri', True, 'b_n_dark elf_f_head_03', 'b_n_dark elf_f_hair_05'),
    ('tmw_worker_03', 'Fadase Llethan', False, 'b_n_dark elf_m_head_05', 'b_n_dark elf_m_hair_07'),
    ('tmw_worker_04', 'Merys Omani', True, 'b_n_dark elf_f_head_06', 'b_n_dark elf_f_hair_02'),
    ('tmw_worker_05', 'Teris Hlervu', False, 'b_n_dark elf_m_head_08', 'b_n_dark elf_m_hair_10'),
    ('tmw_worker_06', 'Nalvyna Rethan', True, 'b_n_dark elf_f_head_08', 'b_n_dark elf_f_hair_11'),
    ('tmw_worker_07', 'Golven Indaram', False, 'b_n_dark elf_m_head_10', 'b_n_dark elf_m_hair_14'),
    ('tmw_worker_08', 'Selvil Drethan', True, 'b_n_dark elf_f_head_09', 'b_n_dark elf_f_hair_16'),
    ('tmw_worker_09', 'Ralen Orvas', False, 'b_n_dark elf_m_head_12', 'b_n_dark elf_m_hair_18'),
    ('tmw_worker_10', 'Tirasa Alen', True, 'b_n_dark elf_f_head_04', 'b_n_dark elf_f_hair_20'),
    ('tmw_worker_11', 'Bralyn Seran', False, 'b_n_dark elf_m_head_03', 'b_n_dark elf_m_hair_21'),
    ('tmw_worker_12', 'Athyn Vedam', True, 'b_n_dark elf_f_head_07', 'b_n_dark elf_f_hair_08'),
]

z = tes3.zstr


def weapon(rid, name, model, icon, wtype):
    wpdt = struct.pack('<fihhffh6Bi',
                       10.0,   # weight
                       5,      # value
                       wtype,
                       800,    # health
                       1.0,    # speed
                       1.0,    # reach
                       0,      # enchant points
                       0, 0, 0, 0, 0, 0,  # chop/slash/thrust min-max
                       0)      # flags
    assert len(wpdt) == 32
    return ('WEAP', [('NAME', z(rid)), ('MODL', z(model)), ('FNAM', z(name)),
                     ('WPDT', wpdt), ('ITEX', z(icon))])


def activator(rid, name, model):
    return ('ACTI', [('NAME', z(rid)), ('MODL', z(model)), ('FNAM', z(name))])


def static(rid, model):
    return ('STAT', [('NAME', z(rid)), ('MODL', z(model))])


def npc(rid, name, female, head, hair, index):
    flags = 0x08 | 0x10 | (0x01 if female else 0)  # base | autocalc | female
    npdt = struct.pack('<hBBB3Bi', 5, 50, 0, 0, 0, 0, 0, 0)
    assert len(npdt) == 12
    clothes = [
        'common_shirt_0%d' % (1 + index % 5),
        ('common_skirt_0%d' if female else 'common_pants_0%d') % (1 + (index + 2) % 5),
        'common_shoes_0%d' % (1 + (index + 1) % 5),
    ]
    items = [t[0] for t in TOOLS] + clothes
    subs = [
        ('NAME', z(rid)), ('FNAM', z(name)), ('RNAM', z('Dark Elf')), ('CNAM', z('Commoner')),
        ('ANAM', z('')), ('BNAM', z(head)), ('KNAM', z(hair)),
        ('NPDT', npdt), ('FLAG', struct.pack('<I', flags)),
    ]
    for item in items:
        subs.append(('NPCO', struct.pack('<i', 1) + tes3.fixed(item, 32)))
    # hello, ?, fight, flee, alarm, ?, ?, ?, services
    # hello = 0: greeting makes NPCs turn toward the player, which would
    # pull workers away from their work target.
    subs.append(('AIDT', struct.pack('<8BI', 0, 0, 0, 30, 0, 0, 0, 0, 0)))
    return ('NPC_', subs)


def main():
    data_files = sys.argv[1]
    master = os.path.join(data_files, 'Morrowind.esm')
    records = []
    records += [weapon(*t) for t in TOOLS]
    records += [activator(*a) for a in ACTIVATORS]
    records += [static(*s) for s in STATICS]
    records += [npc(*w, index=i) for i, w in enumerate(WORKERS)]
    out = os.path.join(ROOT, 'Tomorrowind.esp')
    tes3.write_plugin(out, records, [('Morrowind.esm', os.path.getsize(master))],
                      author='Tomorrowind', description='Hlaalu colony building (prototype)')
    print('wrote', out, len(records), 'records')


if __name__ == '__main__':
    main()
