-- Dev-only: spawns vanilla models out at sea and logs their sizes. Edit MODELS.
local core = require('openmw.core')
local util = require('openmw.util')
local MODELS = { 'x/ex_hlaalu_b_01', 'x/ex_hlaalu_b_02', 'x/ex_hlaalu_b_03', 'x/ex_hlaalu_b_04', 'x/ex_hlaalu_b_05', 'x/ex_hlaalu_b_06', 'x/ex_hlaalu_b_07', 'x/ex_hlaalu_b_08', 'x/ex_hlaalu_b_09', 'x/ex_hlaalu_b_10', 'x/ex_hlaalu_b_11', 'x/ex_hlaalu_b_12', 'x/ex_hlaalu_b_13', 'x/ex_hlaalu_b_14', 'x/ex_hlaalu_b_15', 'x/ex_hlaalu_b_16', 'x/ex_hlaalu_b_17', 'x/ex_hlaalu_b_18', 'x/ex_hlaalu_b_19', 'x/ex_hlaalu_b_20', 'x/ex_hlaalu_b_21', 'x/ex_hlaalu_b_22', 'x/ex_hlaalu_b_23', 'x/ex_hlaalu_b_24', 'x/ex_hlaalu_b_25', 'x/ex_hlaalu_b_26', 'x/ex_hlaalu_b_27', 'x/ex_hlaalu_b_28', 'x/ex_common_building_01', 'x/ex_common_building_02', 'x/ex_common_building_03', 'x/ex_common_house_tall_01', 'x/ex_common_house_tall_02', 'x/ex_common_house_mixedroofs', 'x/ex_de_shack_01', 'x/ex_de_shack_02', 'x/ex_de_shack_03', 'x/ex_de_shack_04', 'x/ex_de_shack_05', 'x/ex_redoran_hut_01', 'x/ex_redoran_hut_02', 'f/furn_com_chair_01', 'f/furn_com_chair_02', 'f/furn_com_chair_03', 'f/furn_de_chair_01', 'f/furn_de_chair_02', 'f/furn_de_chair_03', 'f/furn_com_stool_01', 'f/furn_com_stool_02', 'f/furn_de_stool_01', 'f/furn_de_stool_02', 'f/furn_de_ex_stool_02', 'f/furn_com_bench_01', 'f/furn_com_bench_02', 'f/furn_de_bench_01', 'f/furn_de_bench_02', 'f/furn_de_bench_03', 'f/furn_de_bench_04', 'f/furn_de_ex_bench_01', 'f/furn_com_table_01', 'f/furn_com_table_02', 'f/furn_com_table_03', 'f/furn_com_table_04', 'f/furn_com_table_05', 'f/furn_de_table_01', 'f/furn_de_table_02', 'f/furn_de_table_03', 'f/furn_de_table_04', 'f/furn_de_table_05', 'f/furn_de_ex_table_02', 'f/furn_de_ex_table_03', 'f/furn_com_bookshelf_01', 'f/furn_com_bookshelf_02', 'f/furn_de_bookshelf_01', 'f/furn_de_bookshelf_02', 'o/contain_com_chest_01', 'o/contain_com_chest_02', 'o/contain_de_chest_01', 'o/contain_de_chest_02', 'o/contain_chest_small_01', 'o/contain_chest_small_02', 'o/contain_chest10', 'o/contain_chest_large_01', 'f/active_de_bedroll', 'f/furn_com_bed_01', 'f/furn_com_bed_02', 'f/furn_com_bed_03', 'f/furn_com_bed_04', 'f/active_de_bed_01', 'f/active_de_bed_02', 'f/active_de_bed_03', 'f/active_de_bed_04', 'f/active_de_bed_05', 'f/active_de_bed_06', 'f/furn_firepit00', 'f/furn_de_firepit', 'l/furn_de_firepit_f', 'l/light_pitfire00', 'x/furn_com_fence_01', 'x/furn_com_fence_03', 'x/ex_drystonewall_s_01', 'x/ex_drystonewall_end_01', 'x/ex_drystonewall_c_01', 'x/ex_hlaalu_wall_01', 'x/ex_hlaalu_wall_02', 'x/ex_gg_fence_s_01', 'x/ex_gg_fence_01', 'x/ex_redwall_straight_01', 'x/ex_ashl_tent_01', 'x/ex_ashl_tent_02', 'x/ex_ashl_tent_03', 'x/ex_ashl_tent_04', 'i/in_ashl_tent_01', 'i/in_ashl_tent_02', 'i/in_ashl_tent_03', 'i/in_ashl_tent_04', 'i/in_ashl_tent_05' }
local t, stage = 0, 0
return {
    engineHandlers = {
        onUpdate = function(dt)
            t = t + dt
            if stage == 0 and t > 2 then
                stage = 1
                core.sendGlobalEvent('GAL_Tp', { pos = util.vector3(0, 270000, 20) })
            elseif stage == 1 and t > 3 then
                stage = 2
                core.sendGlobalEvent('GAL_Spawn', { views = { { x = 0, spacing = 60, models = MODELS } }, y = 270000 })
            elseif stage == 2 and t > 5 then
                stage = 3
                core.sendGlobalEvent('GAL_Dump')
            elseif stage == 3 and t > 6 then
                core.quit()
            end
        end,
    },
}
