/*
 Navicat Premium Data Transfer

 Source Server         : 127.0.0.1
 Source Server Type    : MySQL
 Source Server Version : 50648 (5.6.48)
 Source Host           : localhost:3306
 Source Schema         : zmodu_shop_multi_demo

 Target Server Type    : MySQL
 Target Server Version : 50648 (5.6.48)
 File Encoding         : 65001

 Date: 18/11/2025 07:52:27
*/

SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;

-- ----------------------------
-- Table structure for zmodu_ad
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_ad`;
CREATE TABLE `zmodu_ad`  (
  `ad_id` int(11) NOT NULL AUTO_INCREMENT COMMENT '主键ID',
  `title` varchar(30) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL COMMENT '广告名称',
  `image_id` int(11) NOT NULL COMMENT '图片id',
  `sort` int(11) NOT NULL DEFAULT 0 COMMENT '排序(越小越靠前)',
  `link_url` varchar(100) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL COMMENT '跳转链接',
  `name` varchar(120) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL COMMENT '链接名称',
  `category_id` int(11) NOT NULL COMMENT 'banner类型id',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '程序id',
  `shop_supplier_id` int(11) NOT NULL COMMENT '商户id',
  `status` tinyint(1) NOT NULL DEFAULT 1 COMMENT '1显示0隐藏',
  `create_time` int(11) NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(11) NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`ad_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8mb4 COLLATE = utf8mb4_general_ci COMMENT = 'banner图' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_ad
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_ad_category
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_ad_category`;
CREATE TABLE `zmodu_ad_category`  (
  `category_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '类型id',
  `name` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '分类名称',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`category_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8mb4 COLLATE = utf8mb4_general_ci COMMENT = 'banner类型' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_ad_category
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_admin_user
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_admin_user`;
CREATE TABLE `zmodu_admin_user`  (
  `admin_user_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `user_name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '用户名',
  `password` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '登录密码',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(11) NOT NULL COMMENT '更新时间',
  PRIMARY KEY (`admin_user_id`) USING BTREE,
  INDEX `user_name`(`user_name`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 10002 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '超管用户记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_admin_user
-- ----------------------------
INSERT INTO `zmodu_admin_user` VALUES (10001, 'admin', '06e0213dcf92e986d383029494966903', 1529926348, 1595127602);

-- ----------------------------
-- Table structure for zmodu_advance_product
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_advance_product`;
CREATE TABLE `zmodu_advance_product`  (
  `advance_product_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '预售商品主键id',
  `product_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '商品id',
  `limit_num` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '限购数量',
  `stock` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '商品库存总量',
  `sort` int(11) NULL DEFAULT 100 COMMENT '排序',
  `total_sales` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '累计销量',
  `sales_initial` int(11) NULL DEFAULT 0 COMMENT '虚拟销量',
  `join_num` int(11) NULL DEFAULT 0 COMMENT '参与人数',
  `start_time` int(11) NOT NULL DEFAULT 0 COMMENT '预售开始时间',
  `end_time` int(11) NOT NULL DEFAULT 0 COMMENT '预售结束时间',
  `money` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '定金',
  `status` tinyint(4) NOT NULL DEFAULT 10 COMMENT '10上架20下架',
  `reduce_money` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '尾款立减金额',
  `audit_status` tinyint(4) NOT NULL DEFAULT 10 COMMENT '10待审核20通过30拒绝',
  `shop_supplier_id` int(11) NOT NULL DEFAULT 0 COMMENT '供应商id',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '微信app_id',
  `is_delete` int(11) NULL DEFAULT 0 COMMENT '是否删除1，是，0否',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`advance_product_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '预售商品表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_advance_product
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_advance_product_sku
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_advance_product_sku`;
CREATE TABLE `zmodu_advance_product_sku`  (
  `advance_product_sku_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '商品sku id',
  `advance_product_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '预售商品id',
  `product_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '商品id',
  `product_sku_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '商品sku id',
  `product_attr` varchar(500) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '商品规格信息',
  `advance_price` decimal(10, 2) UNSIGNED NOT NULL COMMENT '预售价',
  `advance_stock` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '预售库存',
  `product_price` decimal(10, 2) NULL DEFAULT 0.00 COMMENT '产品售价',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '微信app_id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`advance_product_sku_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '预售商品-sku表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_advance_product_sku
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_agent_apply
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_agent_apply`;
CREATE TABLE `zmodu_agent_apply`  (
  `apply_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `user_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '用户id',
  `real_name` varchar(30) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '姓名',
  `mobile` varchar(20) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '手机号',
  `referee_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '推荐人用户id',
  `apply_type` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '申请方式(10需后台审核 20无需审核)',
  `apply_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '申请时间',
  `apply_status` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '审核状态 (10待审核 20审核通过 30驳回)',
  `audit_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '审核时间',
  `reject_reason` varchar(500) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '驳回原因',
  `app_id` int(10) UNSIGNED NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`apply_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '分销商申请记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_agent_apply
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_agent_capital
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_agent_capital`;
CREATE TABLE `zmodu_agent_capital`  (
  `id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `user_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '分销商用户id',
  `flow_type` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '资金流动类型 (10佣金收入 20提现支出)',
  `money` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '金额',
  `describe` varchar(500) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '描述',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '分销商资金明细表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_agent_capital
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_agent_cash
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_agent_cash`;
CREATE TABLE `zmodu_agent_cash`  (
  `id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `user_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '分销商用户id',
  `money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '提现金额',
  `pay_type` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '打款方式 (10微信 20支付宝 30银行卡40余额)',
  `alipay_name` varchar(30) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '支付宝姓名',
  `alipay_account` varchar(30) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '支付宝账号',
  `bank_name` varchar(30) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '开户行名称',
  `bank_account` varchar(30) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '银行开户名',
  `bank_card` varchar(30) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '银行卡号',
  `apply_status` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '申请状态 (10待审核 20审核通过 30驳回 40已打款 50待用户确认收款)',
  `audit_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '审核时间',
  `reject_reason` varchar(500) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '驳回原因',
  `batch_id` varchar(100) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '商家转账到零钱批号',
  `out_bill_no` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NULL DEFAULT '' COMMENT '商户系统内部的商家单号',
  `package_info` text CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NULL COMMENT '跳转领取页面的package信息',
  `pay_time` int(11) NOT NULL DEFAULT 0 COMMENT '微信发起付款时间',
  `source` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '提现客户端来源',
  `real_money` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '实际到账金额',
  `cash_money` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '手续费',
  `cash_ratio` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '提现手续费比例',
  `out_biz_no` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '支付宝转账商户订单号',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '分销商提现明细表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_agent_cash
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_agent_grade
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_agent_grade`;
CREATE TABLE `zmodu_agent_grade`  (
  `grade_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '等级ID',
  `name` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '等级名称',
  `first_percent` tinyint(4) NULL DEFAULT 0 COMMENT '1级上浮金额,百分比',
  `second_percent` tinyint(4) NULL DEFAULT 0 COMMENT '2级上浮金额,百分比',
  `third_percent` tinyint(4) NULL DEFAULT 0 COMMENT '3级上浮金额,百分比',
  `is_default` tinyint(4) NULL DEFAULT 0 COMMENT '是否默认，1是，0否',
  `remark` varchar(500) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '备注',
  `weight` tinyint(4) NULL DEFAULT 100 COMMENT '权重',
  `auto_upgrade` tinyint(4) NULL DEFAULT 0 COMMENT '是否自动升级0否1是',
  `condition_type` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT 'and' COMMENT '升级条件and和or',
  `image` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '背景图',
  `font_color` varchar(100) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL DEFAULT '#333333' COMMENT '文字颜色',
  `is_delete` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否删除',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`grade_id`) USING BTREE,
  INDEX `app_id`(`app_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 2 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '分销会员等级表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_agent_grade
-- ----------------------------
INSERT INTO `zmodu_agent_grade` VALUES (1, '默认等级', 0, 0, 0, 1, '', 1, 0, 'and', '', '#333333', 0, 10001, 1720666333, 1720666333);

-- ----------------------------
-- Table structure for zmodu_agent_grade_log
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_agent_grade_log`;
CREATE TABLE `zmodu_agent_grade_log`  (
  `log_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `user_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '用户id',
  `old_grade_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '变更前的等级id',
  `new_grade_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '变更后的等级id',
  `change_type` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '变更类型(10后台管理员设置 20自动升级)',
  `remark` varchar(500) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '管理员备注',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  PRIMARY KEY (`log_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '分销商等级变更记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_agent_grade_log
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_agent_grade_task
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_agent_grade_task`;
CREATE TABLE `zmodu_agent_grade_task`  (
  `task_id` int(11) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '任务ID',
  `grade_id` int(11) NOT NULL DEFAULT 0 COMMENT '等级id',
  `name` varchar(100) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '任务名称',
  `number` int(11) NOT NULL DEFAULT 0 COMMENT '任务数量',
  `task_type` tinyint(3) NOT NULL DEFAULT 0 COMMENT '任务类型',
  `status` tinyint(3) NOT NULL DEFAULT 1 COMMENT '状态1显示0隐藏',
  `sort` int(11) NOT NULL DEFAULT 0 COMMENT '排序',
  `is_delete` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否删除',
  `app_id` int(11) UNSIGNED NOT NULL DEFAULT 0 COMMENT '程序id',
  `create_time` int(11) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(11) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`task_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '分销会员等级任务表' ROW_FORMAT = Compact;

-- ----------------------------
-- Records of zmodu_agent_grade_task
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_agent_order
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_agent_order`;
CREATE TABLE `zmodu_agent_order`  (
  `id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `user_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '用户id (买家)',
  `order_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '订单id',
  `order_type` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '订单类型(10商城订单)',
  `order_no` varchar(20) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '订单号(废弃,勿用)',
  `order_price` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '订单总金额(不含运费)',
  `first_user_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '分销商用户id(一级)',
  `second_user_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '分销商用户id(二级)',
  `third_user_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '分销商用户id(三级)',
  `first_money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '分销佣金(一级)',
  `second_money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '分销佣金(二级)',
  `third_money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '分销佣金(三级)',
  `is_invalid` tinyint(4) NOT NULL DEFAULT 0 COMMENT '订单是否失效 (0未失效 1已失效)',
  `is_settled` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否已结算佣金 (0未结算 1已结算)',
  `settle_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '结算时间',
  `shop_supplier_id` int(11) NULL DEFAULT 0 COMMENT '供应商id',
  `total_money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '原分销总佣金',
  `money_type` tinyint(3) NOT NULL DEFAULT 20 COMMENT '佣金计算方式10商品售价 20实付金额',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`id`) USING BTREE,
  INDEX `order_id`(`order_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '分销商订单记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_agent_order
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_agent_poster
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_agent_poster`;
CREATE TABLE `zmodu_agent_poster`  (
  `poster_id` int(11) NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `poster_name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '海报名称',
  `poster_image` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '默认H5海报',
  `poster_wx_image` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '默认小程序海报',
  `poster_data` longtext CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL COMMENT '海报数据',
  `sort` int(11) NOT NULL DEFAULT 0 COMMENT '排序(越小越靠前)',
  `status` tinyint(1) NOT NULL DEFAULT 1 COMMENT '1显示0隐藏',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 10001 COMMENT '应用id',
  `create_time` int(11) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(11) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`poster_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '分销商海报' ROW_FORMAT = Compact;

-- ----------------------------
-- Records of zmodu_agent_poster
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_agent_product
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_agent_product`;
CREATE TABLE `zmodu_agent_product`  (
  `product_id` int(10) UNSIGNED NOT NULL COMMENT '产品id',
  `is_ind_agent` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否开启单独分销(0关闭 1开启)',
  `agent_money_type` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '分销佣金类型(10百分比 20固定金额)',
  `first_money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '分销佣金(一级)',
  `second_money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '分销佣金(二级)',
  `third_money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '分销佣金(三级)',
  `shop_supplier_id` int(11) NOT NULL DEFAULT 0 COMMENT '供应商id',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '应用id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`product_id`) USING BTREE
) ENGINE = InnoDB CHARACTER SET = utf8mb4 COLLATE = utf8mb4_general_ci COMMENT = '分销商品设置表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_agent_product
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_agent_setting
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_agent_setting`;
CREATE TABLE `zmodu_agent_setting`  (
  `key` varchar(30) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '设置项标示',
  `describe` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '设置项描述',
  `values` mediumtext CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL COMMENT '设置内容(json格式)',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  UNIQUE INDEX `unique_key`(`key`, `app_id`) USING BTREE
) ENGINE = InnoDB CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '分销商设置表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_agent_setting
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_agent_user
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_agent_user`;
CREATE TABLE `zmodu_agent_user`  (
  `user_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '分销商用户id',
  `real_name` varchar(30) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '姓名',
  `mobile` varchar(20) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '手机号',
  `money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '当前可提现佣金',
  `freeze_money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '已冻结佣金',
  `total_money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '累积提现佣金',
  `referee_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '推荐人用户id',
  `grade_id` int(11) NULL DEFAULT 0 COMMENT '等级id',
  `is_delete` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否删除',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`user_id`) USING BTREE
) ENGINE = InnoDB CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '分销商用户记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_agent_user
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_agent_user_product
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_agent_user_product`;
CREATE TABLE `zmodu_agent_user_product`  (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `user_id` int(11) NOT NULL DEFAULT 0 COMMENT '分销会员id',
  `product_id` int(11) UNSIGNED NOT NULL DEFAULT 0 COMMENT '产品id',
  `app_id` int(11) UNSIGNED NOT NULL DEFAULT 0 COMMENT '应用id',
  `create_time` int(11) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(11) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '分销会员商品表' ROW_FORMAT = Compact;

-- ----------------------------
-- Records of zmodu_agent_user_product
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_app
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_app`;
CREATE TABLE `zmodu_app`  (
  `app_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '小程序id',
  `app_name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '应用名称',
  `logo` int(11) NULL DEFAULT 0 COMMENT 'logo',
  `passport_open` tinyint(4) NULL DEFAULT 0 COMMENT '通行证是否开发0,不开放1,开放',
  `passport_type` tinyint(4) NULL DEFAULT 10 COMMENT '通行证类型10,微信开放平台,20手机号30,账号密码',
  `is_recycle` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否回收',
  `expire_time` int(11) NULL DEFAULT 0 COMMENT '过期时间',
  `weixin_service` tinyint(4) NULL DEFAULT 0 COMMENT '微信服务商支付是否开启0否1是',
  `pay_type` longtext CHARACTER SET utf8 COLLATE utf8_general_ci NULL COMMENT '支付类型，json格式',
  `mchid` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '微信商户号id',
  `apikey` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '微信支付密钥',
  `cert_pem` longtext CHARACTER SET utf8 COLLATE utf8_general_ci NULL COMMENT '证书文件cert',
  `key_pem` longtext CHARACTER SET utf8 COLLATE utf8_general_ci NULL COMMENT '证书文件key',
  `serial_no` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '证书序列号',
  `platform_pem` longtext CHARACTER SET utf8 COLLATE utf8_general_ci NULL COMMENT '平台证书文件cert',
  `alipay_appid` varchar(100) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '支付宝商户号',
  `alipay_publickey` longtext CHARACTER SET utf8 COLLATE utf8_general_ci NULL COMMENT '支付宝公钥',
  `alipay_privatekey` longtext CHARACTER SET utf8 COLLATE utf8_general_ci NULL COMMENT '应用私钥',
  `wx_cash_type` tinyint(3) NOT NULL DEFAULT 2 COMMENT '微信提现方式1商家转账到零钱2商家发起转账',
  `alipay_cert_path` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '支付宝应用公钥证书名称',
  `is_delete` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否删除',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`app_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 10002 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '微信小程序记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_app
-- ----------------------------
INSERT INTO `zmodu_app` VALUES (10001, '三勾商城', 0, 1, 10, 0, 0, 0, NULL, '', '', NULL, NULL, '', NULL, '', NULL, NULL, 1, '', 0, 1529926348, 1599352830);

-- ----------------------------
-- Table structure for zmodu_app_mp
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_app_mp`;
CREATE TABLE `zmodu_app_mp`  (
  `app_id` int(10) UNSIGNED NOT NULL COMMENT 'appid',
  `mpapp_id` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '公众号AppID',
  `mpapp_secret` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '公众号AppSecret',
  `mchid` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '微信商户号id',
  `apikey` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '微信支付密钥',
  `cert_pem` longtext CHARACTER SET utf8 COLLATE utf8_general_ci NULL COMMENT '证书文件cert',
  `key_pem` longtext CHARACTER SET utf8 COLLATE utf8_general_ci NULL COMMENT '证书文件key',
  `is_recycle` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否回收',
  `is_delete` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否删除',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`app_id`) USING BTREE
) ENGINE = InnoDB CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '微信公众号记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_app_mp
-- ----------------------------
INSERT INTO `zmodu_app_mp` VALUES (10001, '1', '1', '1', '1', '', '', 0, 0, 1970, 1605235766);

-- ----------------------------
-- Table structure for zmodu_app_open
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_app_open`;
CREATE TABLE `zmodu_app_open`  (
  `app_id` int(10) UNSIGNED NOT NULL COMMENT 'appid',
  `openapp_id` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '应用AppID',
  `openapp_secret` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '应用AppSecret',
  `mchid` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '微信商户号id',
  `apikey` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '微信支付密钥',
  `logo` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT 'logo地址',
  `cert_pem` longtext CHARACTER SET utf8 COLLATE utf8_general_ci NULL COMMENT '证书文件cert',
  `key_pem` longtext CHARACTER SET utf8 COLLATE utf8_general_ci NULL COMMENT '证书文件key',
  `is_alipay` tinyint(4) NULL DEFAULT 0 COMMENT '是否支持支付宝支付,0否1是',
  `alipay_appid` varchar(100) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '支付宝商户号',
  `alipay_publickey` longtext CHARACTER SET utf8 COLLATE utf8_general_ci NULL COMMENT '支付宝公钥',
  `alipay_privatekey` longtext CHARACTER SET utf8 COLLATE utf8_general_ci NULL COMMENT '应用私钥',
  `is_recycle` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否回收',
  `is_delete` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否删除',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`app_id`) USING BTREE
) ENGINE = InnoDB CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = 'app应用记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_app_open
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_app_update
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_app_update`;
CREATE TABLE `zmodu_app_update`  (
  `update_id` int(11) NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `app_id` int(10) UNSIGNED NOT NULL COMMENT 'appid',
  `version_android` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT 'android版本号',
  `version_ios` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT 'ios版本号',
  `wgt_url` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '热更新包下载地址',
  `pkg_url_android` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '安卓整包升级地址',
  `pkg_url_ios` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT 'ios整包升级地址',
  `is_delete` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否删除',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`update_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = 'app升级记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_app_update
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_app_wx
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_app_wx`;
CREATE TABLE `zmodu_app_wx`  (
  `app_id` int(10) UNSIGNED NOT NULL COMMENT 'appid',
  `wxapp_id` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '小程序AppID',
  `wxapp_secret` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '小程序AppSecret',
  `mchid` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '微信商户号id',
  `apikey` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '微信支付密钥',
  `cert_pem` longtext CHARACTER SET utf8 COLLATE utf8_general_ci NULL COMMENT '证书文件cert',
  `key_pem` longtext CHARACTER SET utf8 COLLATE utf8_general_ci NULL COMMENT '证书文件key',
  `is_recycle` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否回收',
  `is_delete` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否删除',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`app_id`) USING BTREE
) ENGINE = InnoDB CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '微信小程序记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_app_wx
-- ----------------------------
INSERT INTO `zmodu_app_wx` VALUES (10001, '1', '1', '1', '1', '', '', 0, 0, 1970, 1605235752);

-- ----------------------------
-- Table structure for zmodu_app_wx_live
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_app_wx_live`;
CREATE TABLE `zmodu_app_wx_live`  (
  `live_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '直播间名称',
  `roomid` int(10) UNSIGNED NOT NULL COMMENT '直播间id',
  `cover_img` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '直播间背景图链接',
  `share_img` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '直播间分享图链接',
  `live_status` tinyint(3) UNSIGNED NOT NULL DEFAULT 102 COMMENT '直播间状态。101：直播中，102：未开始，103已结束，104禁播，105：暂停，106：异常，107：已过期',
  `anchor_name` varchar(30) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '主播名',
  `start_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '直播间开始时间',
  `end_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '直播计划结束时间',
  `is_top` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '置顶状态(0未置顶 1已置顶)',
  `is_delete` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '软删除(0未删除 1已删除)',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '应用id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`live_id`) USING BTREE,
  INDEX `roomid`(`roomid`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '微信小程序直播记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_app_wx_live
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_article
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_article`;
CREATE TABLE `zmodu_article`  (
  `article_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '文章id',
  `article_title` varchar(300) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '文章标题',
  `show_type` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '列表显示方式(10小图展示 20大图展示)',
  `category_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '文章分类id',
  `image_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '封面图id',
  `article_content` longtext CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL COMMENT '文章内容',
  `article_sort` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '文章排序(数字越小越靠前)',
  `article_status` tinyint(3) UNSIGNED NOT NULL DEFAULT 1 COMMENT '文章状态(0隐藏 1显示)',
  `virtual_views` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '虚拟阅读量(仅用作展示)',
  `actual_views` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '实际阅读量',
  `is_delete` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否删除',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  `dec` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '描述',
  PRIMARY KEY (`article_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '文章记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_article
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_article_category
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_article_category`;
CREATE TABLE `zmodu_article_category`  (
  `category_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '商品分类id',
  `name` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '分类名称',
  `sort` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '排序方式(数字越小越靠前)',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`category_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '文章分类表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_article_category
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_assemble_bill
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_assemble_bill`;
CREATE TABLE `zmodu_assemble_bill`  (
  `assemble_bill_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT ' 主键id',
  `assemble_product_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '拼团商品id',
  `actual_people` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '当前已拼人数',
  `creator_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '团长用户id',
  `status` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '拼单状态 10拼单中 20拼单成功 30拼单失败',
  `end_time` int(11) NULL DEFAULT 0 COMMENT '拼团结束时间',
  `shop_supplier_id` int(11) NULL DEFAULT 0 COMMENT '供应商id',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT 'app_id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`assemble_bill_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '拼团拼单记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_assemble_bill
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_assemble_bill_user
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_assemble_bill_user`;
CREATE TABLE `zmodu_assemble_bill_user`  (
  `assemble_bill_user_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `assemble_bill_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '拼单记录id',
  `order_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '订单id',
  `user_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '用户id',
  `is_creator` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否为创建者0=否1=是',
  `nickName` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL DEFAULT '' COMMENT '昵称',
  `avatarUrl` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '头像',
  `is_virtual` tinyint(3) NOT NULL DEFAULT 0 COMMENT '虚拟拼团0否1是',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT 'app_id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`assemble_bill_user_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '拼团拼单成员记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_assemble_bill_user
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_assemble_product
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_assemble_product`;
CREATE TABLE `zmodu_assemble_product`  (
  `assemble_product_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '批团商品主键id',
  `product_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '商品id',
  `limit_num` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '限购数量',
  `stock` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '商品库存总量',
  `total_sales` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '累计销量',
  `sales_initial` int(11) NULL DEFAULT 0 COMMENT '虚拟销量',
  `assemble_num` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '开团人数',
  `join_num` int(11) NULL DEFAULT 0 COMMENT '参与人数',
  `sort` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '排序',
  `status` tinyint(4) NULL DEFAULT 0 COMMENT '状态0，待审核 10通过，20未通过',
  `remark` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '审核备注',
  `is_delete` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '0=,展示1,不展示',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT 'app_id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  `shop_supplier_id` int(11) NULL DEFAULT 0 COMMENT '供应商id',
  `state` tinyint(4) NOT NULL DEFAULT 10 COMMENT '商品状态10上架，20下架',
  `start_time` int(10) NOT NULL DEFAULT 0 COMMENT '活动开始时间',
  `end_time` int(10) NOT NULL DEFAULT 0 COMMENT '活动结束时间',
  `image_id` int(11) UNSIGNED NOT NULL DEFAULT 0 COMMENT '商品主图',
  `banner` text CHARACTER SET utf8 COLLATE utf8_general_ci NULL COMMENT '轮播图',
  `product_name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '商品名称',
  `logistics` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '10,20' COMMENT '配送方式',
  `delivery_id` int(11) UNSIGNED NOT NULL DEFAULT 0 COMMENT '配送模板id',
  `together_time` int(10) NOT NULL DEFAULT 0 COMMENT '凑团时间(小时)',
  `fake_num` int(11) NOT NULL DEFAULT 0 COMMENT '虚拟拼团补齐人数',
  `single_num` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '单次限购数量',
  `is_hot` tinyint(3) NOT NULL DEFAULT 0 COMMENT '热门推荐1是',
  `content` text CHARACTER SET utf8 COLLATE utf8_general_ci NULL COMMENT '详情',
  `assemble_price` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '拼团最低价格',
  `product_price` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '产品售价',
  `is_single` tinyint(3) NOT NULL DEFAULT 0 COMMENT '是否单团0否1是',
  `is_show` tinyint(3) NOT NULL DEFAULT 1 COMMENT '是否显示拼单0否1是',
  `selling_point` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '拼团简介',
  PRIMARY KEY (`assemble_product_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '限时拼团商品表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_assemble_product
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_assemble_product_sku
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_assemble_product_sku`;
CREATE TABLE `zmodu_assemble_product_sku`  (
  `assemble_product_sku_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '商品sku id',
  `assemble_product_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '拼团商品id',
  `product_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '商品id',
  `product_sku_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '商品sku id',
  `assemble_stock` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '拼团库存',
  `assemble_price` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '拼团价格',
  `product_attr` varchar(500) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '商品规格说明',
  `product_price` decimal(10, 2) NULL DEFAULT 0.00 COMMENT '产品售价',
  `total_sales` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '累计销量',
  `status` tinyint(3) NULL DEFAULT 0 COMMENT '状态(1生效 0未生效)',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT 'app_id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`assemble_product_sku_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '限时拼团-sku表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_assemble_product_sku
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_balance_order
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_balance_order`;
CREATE TABLE `zmodu_balance_order`  (
  `order_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '订单id',
  `order_no` varchar(20) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '订单号',
  `user_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '用户id',
  `type` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '充值方式(10自定义金额 20套餐充值)',
  `plan_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '充值套餐id',
  `pay_price` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '用户支付金额',
  `give_money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '赠送金额',
  `real_money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '实际到账金额',
  `pay_status` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '支付状态(10待支付 20已支付)',
  `pay_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '付款时间',
  `transaction_id` varchar(30) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '微信支付交易号',
  `snapshot` varchar(500) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '套餐快照json格式',
  `pay_type` tinyint(4) NULL DEFAULT 20 COMMENT '20微信支付',
  `pay_source` varchar(20) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '支付来源,mp,wx',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序appid',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`order_id`) USING BTREE,
  UNIQUE INDEX `order_no`(`order_no`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '充值订单表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_balance_order
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_balance_plan
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_balance_plan`;
CREATE TABLE `zmodu_balance_plan`  (
  `plan_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `plan_name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '套餐名称',
  `money` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '充值金额',
  `give_money` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '赠送金额',
  `real_money` int(11) NULL DEFAULT 0 COMMENT '到账金额',
  `sort` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '排序(数字越小越靠前)',
  `is_delete` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否删除',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序商城id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`plan_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '充值余额套餐表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_balance_plan
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_bargain_product
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_bargain_product`;
CREATE TABLE `zmodu_bargain_product`  (
  `bargain_product_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `product_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '商品id',
  `limit_num` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '限购数量',
  `total_sales` int(11) NOT NULL DEFAULT 0 COMMENT '总销量',
  `sales_initial` int(11) NULL DEFAULT 0 COMMENT '虚拟销量',
  `stock` int(11) NOT NULL DEFAULT 0 COMMENT '库存',
  `join_num` int(11) NULL DEFAULT 0 COMMENT '参与人数',
  `sort` int(11) NOT NULL DEFAULT 0 COMMENT '排序',
  `status` tinyint(4) NULL DEFAULT 0 COMMENT '状态0，待审核 10通过，20未通过',
  `remark` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '审核备注',
  `is_delete` tinyint(4) NULL DEFAULT 0 COMMENT '是否删除',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '微信app_id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  `shop_supplier_id` int(11) NULL DEFAULT 0 COMMENT '供应商id',
  `state` tinyint(4) NOT NULL DEFAULT 10 COMMENT '商品状态10上架，20下架',
  `start_time` int(11) UNSIGNED NOT NULL DEFAULT 0 COMMENT '活动开始时间',
  `end_time` int(11) UNSIGNED NOT NULL DEFAULT 0 COMMENT '活动结束时间',
  `conditions` tinyint(2) UNSIGNED NOT NULL DEFAULT 1 COMMENT '购买条件(0:砍价中可购买，1:砍到底价可购买 )',
  `together_time` int(10) NULL DEFAULT 0 COMMENT '砍价有效时间(小时)',
  `image_id` int(11) UNSIGNED NOT NULL DEFAULT 0 COMMENT '商品主图',
  `banner` text CHARACTER SET utf8 COLLATE utf8_general_ci NULL COMMENT '轮播图',
  `product_name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '商品名称',
  `logistics` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '10,20' COMMENT '配送方式',
  `delivery_id` int(11) UNSIGNED NOT NULL DEFAULT 0 COMMENT '配送模板id',
  `bargain_num` int(11) NOT NULL DEFAULT 0 COMMENT '砍价人数',
  `help_num` int(11) NOT NULL DEFAULT 0 COMMENT '帮砍次数',
  `content` text CHARACTER SET utf8 COLLATE utf8_general_ci NULL COMMENT '详情',
  `bargain_price` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '砍价最低价格',
  `product_price` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '产品售价',
  `selling_point` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '活动简介',
  `rule` text CHARACTER SET utf8 COLLATE utf8_general_ci NULL COMMENT '砍价规则',
  PRIMARY KEY (`bargain_product_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '限时砍价商品表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_bargain_product
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_bargain_product_sku
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_bargain_product_sku`;
CREATE TABLE `zmodu_bargain_product_sku`  (
  `bargain_product_sku_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `bargain_product_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '砍价商品id',
  `product_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '商品id',
  `product_sku_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '商品sku id',
  `bargain_stock` int(11) NOT NULL DEFAULT 0 COMMENT '库存',
  `bargain_price` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '砍价底价',
  `total_sales` int(11) NOT NULL DEFAULT 0 COMMENT '总销量',
  `product_attr` varchar(500) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '商品规格说明',
  `product_price` decimal(10, 2) NULL DEFAULT 0.00 COMMENT '产品售价',
  `status` tinyint(3) NOT NULL DEFAULT 0 COMMENT '状态(1生效 0未生效)',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '微信app_id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`bargain_product_sku_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '限时砍价-sku表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_bargain_product_sku
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_bargain_setting
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_bargain_setting`;
CREATE TABLE `zmodu_bargain_setting`  (
  `key` varchar(30) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '设置项标示',
  `describe` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '设置项描述',
  `values` mediumtext CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL COMMENT '设置内容(json格式)',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  UNIQUE INDEX `unique_key`(`key`, `app_id`) USING BTREE
) ENGINE = InnoDB CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '砍价活动设置表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_bargain_setting
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_bargain_task
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_bargain_task`;
CREATE TABLE `zmodu_bargain_task`  (
  `bargain_task_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '砍价任务id',
  `user_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '用户id(发起人)',
  `bargain_product_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '商品id',
  `bargain_product_sku_id` int(11) NOT NULL DEFAULT 0 COMMENT '商品sku标识',
  `product_sku_id` int(11) NULL DEFAULT 0 COMMENT '商品规格id',
  `product_price` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '商品原价',
  `bargain_price` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '砍价底价',
  `product_name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '商品名称',
  `image_id` int(11) NULL DEFAULT 0 COMMENT '商品封面图片id',
  `product_attr` varchar(500) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '商品规格',
  `peoples` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '帮砍人数',
  `cut_people` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '已砍人数',
  `section` text CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL COMMENT '砍价金额区间',
  `cut_money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '已砍金额',
  `actual_price` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '实际购买金额',
  `is_floor` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否已砍到底价(0否 1是)',
  `end_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '任务截止时间',
  `is_buy` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否购买(0未购买 1已购买)',
  `status` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '任务状态 (0砍价中 1砍价成功 2砍价失败)',
  `shop_supplier_id` int(11) NULL DEFAULT 0 COMMENT '供应商id',
  `is_delete` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否删除',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`bargain_task_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '砍价任务表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_bargain_task
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_bargain_task_help
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_bargain_task_help`;
CREATE TABLE `zmodu_bargain_task_help`  (
  `bargain_task_help_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `bargain_product_id` int(11) UNSIGNED NOT NULL DEFAULT 0 COMMENT '商品id',
  `bargain_task_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '砍价任务id',
  `user_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '用户id',
  `is_creater` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否为发起人(0否 1是)',
  `cut_money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '砍掉的金额',
  `shop_supplier_id` int(11) NOT NULL DEFAULT 0 COMMENT '供应商id',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  PRIMARY KEY (`bargain_task_help_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '砍价任务助力记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_bargain_task_help
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_buy_activity
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_buy_activity`;
CREATE TABLE `zmodu_buy_activity`  (
  `buy_id` int(11) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '活动名称',
  `product_ids` longtext CHARACTER SET utf8 COLLATE utf8_general_ci NULL COMMENT '赠送商品',
  `sort` int(11) NULL DEFAULT 100 COMMENT '排序',
  `start_time` int(10) NOT NULL DEFAULT 0 COMMENT '开始时间',
  `end_time` int(10) NOT NULL DEFAULT 0 COMMENT '结束时间',
  `status` tinyint(3) NOT NULL DEFAULT 1 COMMENT '活动状态1开启0关闭',
  `audit_status` tinyint(3) NOT NULL DEFAULT 10 COMMENT '审核状态10待审核 20通过 30未通过',
  `send_type` tinyint(3) NOT NULL DEFAULT 10 COMMENT '赠送类型10单次赠送20倍数赠送',
  `max_times` int(11) NOT NULL DEFAULT 1 COMMENT '赠送最大倍数',
  `shop_supplier_id` int(11) NULL DEFAULT 0 COMMENT '供应商id',
  `is_delete` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '0=显示1=伪删除',
  `app_id` int(11) UNSIGNED NOT NULL DEFAULT 0 COMMENT '程序id',
  `create_time` int(11) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(11) NOT NULL COMMENT '更新时间',
  PRIMARY KEY (`buy_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8mb4 COLLATE = utf8mb4_general_ci COMMENT = '买送活动' ROW_FORMAT = Compact;

-- ----------------------------
-- Records of zmodu_buy_activity
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_buy_activity_product
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_buy_activity_product`;
CREATE TABLE `zmodu_buy_activity_product`  (
  `buy_product_id` int(11) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `buy_id` int(11) NOT NULL DEFAULT 0 COMMENT '活动id',
  `product_name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '商品名称',
  `product_id` int(11) NOT NULL DEFAULT 0 COMMENT '购买商品id',
  `product_num` int(11) NOT NULL DEFAULT 0 COMMENT '购买商品数量',
  `shop_supplier_id` int(11) NULL DEFAULT 0 COMMENT '供应商id',
  `app_id` int(11) UNSIGNED NOT NULL DEFAULT 0 COMMENT '程序id',
  `create_time` int(11) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(11) NOT NULL COMMENT '更新时间',
  PRIMARY KEY (`buy_product_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8mb4 COLLATE = utf8mb4_general_ci COMMENT = '买送活动购买商品' ROW_FORMAT = Compact;

-- ----------------------------
-- Records of zmodu_buy_activity_product
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_category
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_category`;
CREATE TABLE `zmodu_category`  (
  `category_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '产品分类id',
  `name` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '分类名称',
  `parent_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '上级分类id',
  `image_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '分类图片id',
  `sort` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '排序方式(数字越小越靠前)',
  `status` tinyint(1) NOT NULL DEFAULT 1 COMMENT '是否显示1显示0隐藏',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '应用id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`category_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 58 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '产品分类表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_category
-- ----------------------------
INSERT INTO `zmodu_category` VALUES (1, '家电', 0, 4, 100, 1, 10001, 1572087164, 1720665843);
INSERT INTO `zmodu_category` VALUES (3, '数码', 0, 1, 100, 1, 10001, 1572087164, 1720665859);
INSERT INTO `zmodu_category` VALUES (6, '摄影摄像', 3, 1, 100, 1, 10001, 1573122035, 1720665862);
INSERT INTO `zmodu_category` VALUES (16, '厨房小电', 1, 4, 100, 1, 10001, 1577166766, 1720665847);
INSERT INTO `zmodu_category` VALUES (57, '洗衣机', 1, 3, 100, 1, 10001, 1590801294, 1720665854);

-- ----------------------------
-- Table structure for zmodu_center_menu
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_center_menu`;
CREATE TABLE `zmodu_center_menu`  (
  `menu_id` int(11) NOT NULL AUTO_INCREMENT COMMENT '主键ID',
  `title` varchar(30) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL COMMENT '菜单名称',
  `image_url` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL DEFAULT '' COMMENT '图片url',
  `sort` int(11) NOT NULL DEFAULT 0 COMMENT '排序(越小越靠前)',
  `link_url` varchar(100) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL COMMENT '跳转链接',
  `name` varchar(120) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL DEFAULT '' COMMENT '链接名称',
  `sys_tag` varchar(30) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL DEFAULT '' COMMENT '标签',
  `status` tinyint(1) NOT NULL DEFAULT 1 COMMENT '1显示0隐藏',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '程序id',
  `create_time` int(11) NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(11) NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`menu_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8mb4 COLLATE = utf8mb4_general_ci COMMENT = 'banner图' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_center_menu
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_chat
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_chat`;
CREATE TABLE `zmodu_chat`  (
  `chat_id` int(11) NOT NULL AUTO_INCREMENT COMMENT '消息id',
  `status` tinyint(1) NOT NULL DEFAULT 0 COMMENT '0未读1已读',
  `user_id` int(11) NOT NULL DEFAULT 0 COMMENT '发送者id',
  `app_id` int(11) NOT NULL DEFAULT 0 COMMENT '应用id',
  `content` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL DEFAULT '' COMMENT '内容',
  `type` tinyint(1) NOT NULL DEFAULT 0 COMMENT '0普通内容1图片2商品3订单信息',
  `msg_type` tinyint(4) NULL DEFAULT 1 COMMENT '消息类型1，用户收到，2用户发送',
  `shop_supplier_id` int(11) NOT NULL DEFAULT 0 COMMENT '供应商id',
  `chat_user_id` int(11) NULL DEFAULT 0 COMMENT '客服id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(11) NOT NULL COMMENT '更新时间',
  PRIMARY KEY (`chat_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8mb4 COLLATE = utf8mb4_general_ci COMMENT = '客服信息' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_chat
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_chat_relation
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_chat_relation`;
CREATE TABLE `zmodu_chat_relation`  (
  `relation_id` int(11) NOT NULL AUTO_INCREMENT COMMENT 'id',
  `user_id` int(11) NOT NULL DEFAULT 0 COMMENT '用户id',
  `shop_supplier_id` int(11) NOT NULL DEFAULT 0 COMMENT '供应商id',
  `chat_user_id` int(11) NULL DEFAULT 0 COMMENT '客服id',
  `app_id` int(11) NOT NULL DEFAULT 0 COMMENT '应用id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(11) NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`relation_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8mb4 COLLATE = utf8mb4_general_ci COMMENT = '消息记录关系表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_chat_relation
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_chat_user
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_chat_user`;
CREATE TABLE `zmodu_chat_user`  (
  `chat_user_id` int(11) NOT NULL AUTO_INCREMENT COMMENT 'ID',
  `user_id` int(11) NOT NULL DEFAULT 0 COMMENT '会员id',
  `user_name` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL DEFAULT '' COMMENT '登录账号',
  `password` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL DEFAULT '' COMMENT '登录密码',
  `nick_name` varchar(100) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL DEFAULT '' COMMENT '客服名称',
  `avatarUrl` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL DEFAULT '' COMMENT '头像',
  `shop_supplier_id` int(11) NOT NULL DEFAULT 0 COMMENT '供应商id',
  `type` tinyint(4) NOT NULL DEFAULT 0 COMMENT '客服类型，1=商户，2=平台',
  `sort` int(11) NOT NULL DEFAULT 0 COMMENT '排序',
  `status` tinyint(4) NOT NULL DEFAULT 1 COMMENT '账号状态，0=关闭，1=正常',
  `is_delete` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '0=显示1=伪删除',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(11) NOT NULL COMMENT '更新时间',
  PRIMARY KEY (`chat_user_id`) USING BTREE,
  INDEX `user_name`(`user_name`(191)) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8mb4 COLLATE = utf8mb4_general_ci COMMENT = '客服用户表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_chat_user
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_comment
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_comment`;
CREATE TABLE `zmodu_comment`  (
  `comment_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '评价id',
  `score` tinyint(4) NULL DEFAULT 10 COMMENT '评分 (10好评 20中评 30差评)',
  `express_score` tinyint(3) UNSIGNED NOT NULL DEFAULT 5 COMMENT '物流服务评分总分5分',
  `server_score` tinyint(3) UNSIGNED NOT NULL DEFAULT 5 COMMENT '服务态度评分总分5分',
  `describe_score` tinyint(4) NULL DEFAULT 5 COMMENT '描述评分',
  `content` text CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL COMMENT '评价内容',
  `is_picture` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否为图片评价',
  `sort` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '评价排序',
  `status` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '评价状态(0=待审核 1=审核通过2=审核不通过)',
  `user_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '用户id',
  `order_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '订单id',
  `product_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '商品id',
  `order_product_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '订单商品id',
  `shop_supplier_id` int(11) NULL DEFAULT 0 COMMENT '供应商id',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `is_delete` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '软删除',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`comment_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '订单评价记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_comment
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_comment_image
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_comment_image`;
CREATE TABLE `zmodu_comment_image`  (
  `id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `comment_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '评价id',
  `image_id` int(11) NOT NULL DEFAULT 0 COMMENT '图片id(关联文件记录表)',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  PRIMARY KEY (`id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '订单评价图片记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_comment_image
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_coupon
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_coupon`;
CREATE TABLE `zmodu_coupon`  (
  `coupon_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '优惠券id',
  `name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '优惠券名称',
  `color` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '优惠券颜色(10蓝 20红 30紫 40黄)',
  `coupon_type` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '优惠券类型(10满减券 20折扣券)',
  `reduce_price` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '满减券-减免金额',
  `discount` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '折扣券-折扣率(0-100)',
  `min_price` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '最低消费金额',
  `expire_type` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '到期类型(10领取后生效 20固定时间)',
  `expire_day` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '领取后生效-有效天数',
  `start_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '固定时间-开始时间',
  `end_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '固定时间-结束时间',
  `apply_range` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '适用范围(10全部商品 20指定商品 30指定分类)',
  `product_ids` longtext CHARACTER SET utf8 COLLATE utf8_general_ci NULL COMMENT '限制商品id',
  `category_ids` longtext CHARACTER SET utf8 COLLATE utf8_general_ci NULL COMMENT '限制分类id',
  `total_num` int(11) NOT NULL DEFAULT 0 COMMENT '发放总数量(-1为不限制)',
  `receive_num` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '已领取数量',
  `shop_supplier_id` int(11) NOT NULL COMMENT '供应商id',
  `sort` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '排序方式(数字越小越靠前)',
  `show_center` tinyint(4) NULL DEFAULT 1 COMMENT '是否显示领券中心，0否1是',
  `free_limit` tinyint(4) NULL DEFAULT 0 COMMENT '优惠限制0不显示1不可与促销同时2不可与等级优惠同时3不可于促销和等级同时',
  `max_price` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '最多抵扣金额',
  `content` longtext CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL COMMENT '规则',
  `is_delete` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '软删除',
  `app_id` int(10) UNSIGNED NULL DEFAULT 0 COMMENT '程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`coupon_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '优惠券记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_coupon
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_delivery
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_delivery`;
CREATE TABLE `zmodu_delivery`  (
  `delivery_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '模板id',
  `name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '模板名称',
  `method` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '计费方式(10按件数 20按重量)',
  `shop_supplier_id` int(11) NULL DEFAULT 0 COMMENT '供应商id',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序d',
  `sort` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '排序方式(数字越小越靠前)',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`delivery_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 10012 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '配送模板主表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_delivery
-- ----------------------------
INSERT INTO `zmodu_delivery` VALUES (10011, '全国包邮', 10, 10001, 10001, 1, 1572873840, 1605015675);

-- ----------------------------
-- Table structure for zmodu_delivery_rule
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_delivery_rule`;
CREATE TABLE `zmodu_delivery_rule`  (
  `rule_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '规则id',
  `delivery_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '配送模板id',
  `region` text CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL COMMENT '可配送区域(城市id集)',
  `first` double UNSIGNED NOT NULL DEFAULT 0 COMMENT '首件(个)/首重(Kg)',
  `first_fee` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '运费(元)',
  `additional` double UNSIGNED NOT NULL DEFAULT 0 COMMENT '续件/续重',
  `additional_fee` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '续费(元)',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL COMMENT '创建时间',
  PRIMARY KEY (`rule_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 16 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '配送模板区域及运费表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_delivery_rule
-- ----------------------------
INSERT INTO `zmodu_delivery_rule` VALUES (15, 10011, '2,20,38,61,76,84,104,124,150,168,180,197,208,221,232,244,250,264,271,278,290,304,319,337,352,362,372,376,389,398,407,422,430,442,449,462,467,481,492,500,508,515,522,530,537,545,553,558,566,574,581,586,597,607,614,619,627,634,640,646,656,675,692,702,711,720,730,748,759,764,775,782,793,802,821,833,842,853,861,871,880,887,896,906,913,920,927,934,948,960,972,980,986,993,1003,1010,1015,1025,1035,1047,1057,1066,1074,1081,1088,1093,1098,1110,1118,1127,1136,1142,1150,1155,1160,1169,1183,1190,1196,1209,1222,1234,1245,1253,1264,1274,1279,1285,1299,1302,1306,1325,1339,1350,1362,1376,1387,1399,1408,1415,1421,1434,1447,1459,1466,1471,1476,1479,1492,1504,1513,1522,1533,1546,1556,1572,1583,1593,1599,1612,1623,1630,1637,1643,1650,1664,1674,1685,1696,1707,1710,1724,1731,1740,1754,1764,1768,1774,1782,1791,1802,1809,1813,1822,1828,1838,1848,1854,1867,1880,1890,1900,1905,1912,1924,1936,1949,1955,1965,1977,1988,1999,2003,2011,2017,2025,2035,2041,2050,2056,2065,2070,2077,2082,2091,2123,2146,2150,2156,2163,2177,2189,2207,2215,2220,2225,2230,2236,2245,2258,2264,2276,2283,2292,2297,2302,2306,2324,2363,2368,2388,2395,2401,2409,2416,2426,2434,2440,2446,2458,2468,2475,2486,2493,2501,2510,2516,2521,2535,2554,2573,2584,2589,2604,2611,2620,2631,2640,2657,2671,2686,2696,2706,2712,2724,2730,2741,2750,2761,2775,2784,2788,2801,2807,2812,2817,2826,2845,2857,2870,2882,2890,2899,2913,2918,2931,2946,2958,2972,2984,2997,3008,3016,3023,3032,3036,3039,3045,3053,3058,3065,3073,3081,3090,3098,3108,3117,3127,3135,3142,3147,3152,3158,3165,3172,3179,3186,3190,3196,3202,3207,3216,3221,3225,3229,3237,3242,3252,3262,3267,3280,3289,3301,3309,3317,3326,3339,3378,3386,3416,3454,3458,3461,3491,3504,3518,3532,3551,3578,3592,3613,3632,3666,3683,3697,3704,3711,3717,3722,3728,3999,3739,3745,3747', 1, 0.00, 1, 0.00, 10001, 1605015675);

-- ----------------------------
-- Table structure for zmodu_delivery_setting
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_delivery_setting`;
CREATE TABLE `zmodu_delivery_setting`  (
  `setting_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '电子面单设置id',
  `setting_name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '电子面单设置名称',
  `express_id` int(11) NOT NULL DEFAULT 0 COMMENT '物流公司id',
  `partner_id` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '电子面单客户账户或月结账号，需贵司向当地快递公司网点申请',
  `partner_key` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '电子面单密码',
  `partner_secret` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '电子面单密钥',
  `partner_name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '电子面单客户账户名称',
  `net` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '收件网点名称',
  `code` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '电子面单承载编号',
  `check_man` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '电子面单承载快递员名',
  `sort` int(11) NOT NULL DEFAULT 0 COMMENT '排序方式(数字越小越靠前)',
  `shop_supplier_id` int(11) NOT NULL DEFAULT 0 COMMENT '供应商id',
  `is_delete` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否删除',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`setting_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '电子面单设置主表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_delivery_setting
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_delivery_template
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_delivery_template`;
CREATE TABLE `zmodu_delivery_template`  (
  `template_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '模板id',
  `template_num` varchar(150) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '电子面单模板编码',
  `template_name` varchar(150) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '电子面单模板名称',
  `sort` int(11) NOT NULL DEFAULT 0 COMMENT '排序方式(数字越小越靠前)',
  `shop_supplier_id` int(11) NULL DEFAULT 0 COMMENT '供应商id',
  `is_delete` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否删除',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`template_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '电子面单模板主表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_delivery_template
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_express
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_express`;
CREATE TABLE `zmodu_express`  (
  `express_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '物流公司id',
  `express_name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '物流公司名称',
  `express_code` varchar(30) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '物流公司代码 (快递100)',
  `wx_code` varchar(30) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '物流公司代码（微信小程序）',
  `sort` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '排序 (数字越小越靠前)',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`express_id`) USING BTREE,
  INDEX `express_code`(`express_code`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 10008 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '物流公司记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_express
-- ----------------------------
INSERT INTO `zmodu_express` VALUES (10001, '顺丰速运', 'shunfeng', '', 1001, 10001, 1535160797, 1577153572);
INSERT INTO `zmodu_express` VALUES (10002, '邮政国内', 'yzguonei', '', 100, 10001, 1535942653, 1535942653);
INSERT INTO `zmodu_express` VALUES (10003, '圆通速递', 'yuantong', '', 100, 10001, 1535942675, 1535942675);
INSERT INTO `zmodu_express` VALUES (10004, '申通快递', 'shentong', '', 100, 10001, 1535942694, 1535942694);
INSERT INTO `zmodu_express` VALUES (10005, '韵达快递', 'yunda', '', 100, 10001, 1535942711, 1535942711);
INSERT INTO `zmodu_express` VALUES (10006, '百世快递', 'huitongkuaidi', '', 100, 10001, 1535942743, 1535942743);
INSERT INTO `zmodu_express` VALUES (10007, '中通快递', 'zhongtong', '', 1001, 10001, 1535942764, 1577176947);

-- ----------------------------
-- Table structure for zmodu_image_bank
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_image_bank`;
CREATE TABLE `zmodu_image_bank`  (
  `category_id` int(11) NOT NULL AUTO_INCREMENT COMMENT '图库id',
  `name` varchar(50) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL DEFAULT '' COMMENT '图库名称',
  `parent_id` int(11) NOT NULL DEFAULT 0 COMMENT '上级图库id',
  `image` varchar(500) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL DEFAULT '' COMMENT '图片路径',
  `sort` int(11) NOT NULL DEFAULT 0 COMMENT '排序方式(数字越小越靠前)',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`category_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 153 CHARACTER SET = utf8mb4 COLLATE = utf8mb4_general_ci COMMENT = '系统图片库表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_image_bank
-- ----------------------------
INSERT INTO `zmodu_image_bank` VALUES (1, '金刚区', 0, 'https://qn-cdn.jjjshop.net/20231026181611890.png', 1, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (2, '个人中心', 0, 'https://qn-cdn.jjjshop.net/20231030174852349.png', 2, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (3, '底部导航', 0, 'https://qn-cdn.jjjshop.net/20231027162932318.png', 3, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (4, '万能表单1', 1, 'https://qn-cdn.jjjshop.net/20231101092214490.png', 1, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (7, '万能表单3', 1, 'https://qn-cdn.jjjshop.net/20231101092210908.png', 3, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (8, '万能表单2', 1, 'https://qn-cdn.jjjshop.net/20231101092212352.png', 2, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (9, '万能表单4', 1, 'https://qn-cdn.jjjshop.net/20231101092210009.png', 4, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (10, '万能表单5', 1, 'https://qn-cdn.jjjshop.net/20231101092208995.png', 5, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (11, '万能表单6', 1, 'https://qn-cdn.jjjshop.net/20231101092209350.png', 6, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (12, '万能表单7', 1, 'https://qn-cdn.jjjshop.net/20231101092207582.png', 7, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (13, '新闻1', 1, 'https://qn-cdn.jjjshop.net/20231101092206109.png', 9, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (14, '新闻2', 1, 'https://qn-cdn.jjjshop.net/20231101092205126.png', 10, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (15, '万能表单8', 1, 'https://qn-cdn.jjjshop.net/20231101092207298.png', 8, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (16, '新闻3', 1, 'https://qn-cdn.jjjshop.net/20231101092203912.png', 11, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (17, '新闻4', 1, 'https://qn-cdn.jjjshop.net/20231101092202488.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (18, '新闻5', 1, 'https://qn-cdn.jjjshop.net/20231101092202178.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (19, '新闻6', 1, 'https://qn-cdn.jjjshop.net/20231101092158849.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (20, '新闻7', 1, 'https://qn-cdn.jjjshop.net/20231101092159642.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (21, '新闻8', 1, 'https://qn-cdn.jjjshop.net/20231101092158339.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (22, '分销1', 1, 'https://qn-cdn.jjjshop.net/20231101092201198.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (23, '分销2', 1, 'https://qn-cdn.jjjshop.net/20231101092200231.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (24, '分销3', 1, 'https://qn-cdn.jjjshop.net/20231101092157815.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (25, '分销4', 1, 'https://qn-cdn.jjjshop.net/20231101092155968.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (26, '分销5', 1, 'https://qn-cdn.jjjshop.net/20231101092157245.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (27, '分销6', 1, 'https://qn-cdn.jjjshop.net/20231101092154786.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (28, '分销7', 1, 'https://qn-cdn.jjjshop.net/20231101092153594.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (29, '分销8', 1, 'https://qn-cdn.jjjshop.net/20231101092148059.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (30, '收货地址1', 1, 'https://qn-cdn.jjjshop.net/20231101092146733.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (31, '收货地址2', 1, 'https://qn-cdn.jjjshop.net/20231101092152324.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (32, '收货地址3', 1, 'https://qn-cdn.jjjshop.net/20231101092150716.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (33, '收货地址4', 1, 'https://qn-cdn.jjjshop.net/20231101092149349.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (34, '收货地址5', 1, 'https://qn-cdn.jjjshop.net/20231101092148834.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (35, '收货地址6', 1, 'https://qn-cdn.jjjshop.net/20231101092145922.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (36, '收货地址7', 1, 'https://qn-cdn.jjjshop.net/20231101092146435.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (37, '收货地址8', 1, 'https://qn-cdn.jjjshop.net/20231101092144721.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (38, '任务中心1', 1, 'https://qn-cdn.jjjshop.net/20231101092147502.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (39, '任务中心2', 1, 'https://qn-cdn.jjjshop.net/20231101092143148.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (40, '任务中心3', 1, 'https://qn-cdn.jjjshop.net/20231101092144414.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (41, '任务中心4', 1, 'https://qn-cdn.jjjshop.net/20231101092142178.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (42, '任务中心5', 1, 'https://qn-cdn.jjjshop.net/20231101092140962.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (43, '任务中心6', 1, 'https://qn-cdn.jjjshop.net/20231101092139791.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (44, '任务中心7', 1, 'https://qn-cdn.jjjshop.net/20231101092136780.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (45, '任务中心8', 1, 'https://qn-cdn.jjjshop.net/20231101092135996.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (46, '拼团1', 1, 'https://qn-cdn.jjjshop.net/20231101092138577.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (47, '拼团2', 1, 'https://qn-cdn.jjjshop.net/20231101092137556.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (48, '拼团3', 1, 'https://qn-cdn.jjjshop.net/20231101092134177.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (49, '拼团4', 1, 'https://qn-cdn.jjjshop.net/20231101092135123.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (50, '拼团5', 1, 'https://qn-cdn.jjjshop.net/20231101092135687.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (51, '拼团6', 1, 'https://qn-cdn.jjjshop.net/20231101092132989.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (52, '拼团7', 1, 'https://qn-cdn.jjjshop.net/20231101092131836.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (53, '拼团8', 1, 'https://qn-cdn.jjjshop.net/20231101092126862.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (54, '优惠券1', 1, 'https://qn-cdn.jjjshop.net/20231101092130601.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (55, '优惠券2', 1, 'https://qn-cdn.jjjshop.net/20231101092129371.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (56, '优惠券3', 1, 'https://qn-cdn.jjjshop.net/20231101092127951.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (57, '优惠券4', 1, 'https://qn-cdn.jjjshop.net/20231101092127150.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (58, '优惠券5', 1, 'https://qn-cdn.jjjshop.net/20231101092124998.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (59, '优惠券6', 1, 'https://qn-cdn.jjjshop.net/20231101092125301.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (60, '优惠券7', 1, 'https://qn-cdn.jjjshop.net/20231101092123439.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (61, '优惠券8', 1, 'https://qn-cdn.jjjshop.net/20231101092124388.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (62, '砍价1', 1, 'https://qn-cdn.jjjshop.net/20231101092125874.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (63, '砍价2', 1, 'https://qn-cdn.jjjshop.net/20231101092122898.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (64, '砍价3', 1, 'https://qn-cdn.jjjshop.net/20231101092120519.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (65, '砍价4', 1, 'https://qn-cdn.jjjshop.net/20231101092121708.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (66, '砍价5', 1, 'https://qn-cdn.jjjshop.net/20231101092119310.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (67, '砍价6', 1, 'https://qn-cdn.jjjshop.net/20231101092117424.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (68, '砍价7', 1, 'https://qn-cdn.jjjshop.net/20231101092114255.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (69, '砍价8', 1, 'https://qn-cdn.jjjshop.net/20231101092113479.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (70, '秒杀', 1, 'https://qn-cdn.jjjshop.net/20231101092116227.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (71, '秒杀2', 1, 'https://qn-cdn.jjjshop.net/20231101092115919.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (72, '秒杀3', 1, 'https://qn-cdn.jjjshop.net/20231101092114777.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (73, '秒杀4', 1, 'https://qn-cdn.jjjshop.net/20231101092112725.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (74, '秒杀5', 1, 'https://qn-cdn.jjjshop.net/20231101092112174.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (75, '秒杀6', 1, 'https://qn-cdn.jjjshop.net/20231101092110521.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (76, '秒杀7', 1, 'https://qn-cdn.jjjshop.net/20231101092111121.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (77, '秒杀8', 1, 'https://qn-cdn.jjjshop.net/20231101092109204.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (78, '积分商城1', 1, 'https://qn-cdn.jjjshop.net/20231101092108007.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (79, '积分商城2', 1, 'https://qn-cdn.jjjshop.net/20231101092106813.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (80, '积分商城3', 1, 'https://qn-cdn.jjjshop.net/20231101092105598.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (81, '积分商城4', 1, 'https://qn-cdn.jjjshop.net/20231101092104403.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (82, '积分商城5', 1, 'https://qn-cdn.jjjshop.net/20231101092103891.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (83, '积分商城6', 1, 'https://qn-cdn.jjjshop.net/20231101092101654.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (84, '积分商城7', 1, 'https://qn-cdn.jjjshop.net/20231101092059805.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (85, '积分商城8', 1, 'https://qn-cdn.jjjshop.net/20231101092101053.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (86, '签到1', 1, 'https://qn-cdn.jjjshop.net/20231101092103581.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (87, '签到2', 1, 'https://qn-cdn.jjjshop.net/20231101092058950.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (88, '签到3', 1, 'https://qn-cdn.jjjshop.net/20231101092059272.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (89, '签到4', 1, 'https://qn-cdn.jjjshop.net/20231101092057980.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (90, '签到5', 1, 'https://qn-cdn.jjjshop.net/20231101092054837.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (91, '签到6', 1, 'https://qn-cdn.jjjshop.net/20231101092056789.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (92, '签到7', 1, 'https://qn-cdn.jjjshop.net/20231101092052181.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (93, '签到8', 1, 'https://qn-cdn.jjjshop.net/20231101092051643.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (94, '首页1', 3, 'https://qn-cdn.jjjshop.net/20231101091943796.png', 101, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (95, '首页2', 3, 'https://qn-cdn.jjjshop.net/20231101091942585.png', 101, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (96, '分类1', 3, 'https://qn-cdn.jjjshop.net/20231101091948850.png', 104, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (97, '店铺1', 3, 'https://qn-cdn.jjjshop.net/20231101091949638.png', 103, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (98, '我的1', 3, 'https://qn-cdn.jjjshop.net/20231101091948072.png', 106, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (99, '订单1', 3, 'https://qn-cdn.jjjshop.net/20231101091946994.png', 102, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (100, '购物车1', 3, 'https://qn-cdn.jjjshop.net/20231101091945766.png', 105, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (101, '店铺2', 3, 'https://qn-cdn.jjjshop.net/20231101091944923.png', 103, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (102, '购物车2', 3, 'https://qn-cdn.jjjshop.net/20231101091945221.png', 105, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (103, '分类2', 3, 'https://qn-cdn.jjjshop.net/20231101091944569.png', 104, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (104, '分类3', 3, 'https://qn-cdn.jjjshop.net/20231101091943196.png', 104, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (105, '提现', 2, 'https://qn-cdn.jjjshop.net/20231101092411715.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (106, '我的2', 3, 'https://qn-cdn.jjjshop.net/20231101091942057.png', 106, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (107, '我的3', 3, 'https://qn-cdn.jjjshop.net/20231101091940706.png', 106, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (108, '订单2', 3, 'https://qn-cdn.jjjshop.net/20231101091941274.png', 102, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (109, '订单3', 3, 'https://qn-cdn.jjjshop.net/20231101091939938.png', 102, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (110, '店铺3', 3, 'https://qn-cdn.jjjshop.net/20231101091938763.png', 103, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (111, '购物车3', 3, 'https://qn-cdn.jjjshop.net/20231101091939264.png', 105, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (112, '购物车5', 3, 'https://qn-cdn.jjjshop.net/20231101091938201.png', 105, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (113, '分类4', 3, 'https://qn-cdn.jjjshop.net/20231101091936782.png', 104, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (114, '店铺4', 3, 'https://qn-cdn.jjjshop.net/20231101091937357.png', 103, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (115, '首页3', 3, 'https://qn-cdn.jjjshop.net/20231101091936201.png', 101, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (116, '首页4', 3, 'https://qn-cdn.jjjshop.net/20231101091934631.png', 101, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (117, '分类5', 3, 'https://qn-cdn.jjjshop.net/20231101091935433.png', 104, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (118, '我的积分', 2, 'https://qn-cdn.jjjshop.net/20231101092406880.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (119, '我的关注', 2, 'https://qn-cdn.jjjshop.net/20231101092409743.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (120, '我的团队', 2, 'https://qn-cdn.jjjshop.net/20231101092408142.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (121, '订单4', 3, 'https://qn-cdn.jjjshop.net/20231101091929006.png', 102, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (122, '购物车4', 3, 'https://qn-cdn.jjjshop.net/20231101091927786.png', 105, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (123, '分类6', 3, 'https://qn-cdn.jjjshop.net/20231101091928365.png', 104, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (124, '首页5', 3, 'https://qn-cdn.jjjshop.net/20231101091926774.png', 101, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (125, '店铺5', 3, 'https://qn-cdn.jjjshop.net/20231101091927437.png', 103, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (126, '我的4', 3, 'https://qn-cdn.jjjshop.net/20231101091929795.png', 106, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (127, '店铺6', 3, 'https://qn-cdn.jjjshop.net/20231101091930248.png', 103, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (128, '客服', 2, 'https://qn-cdn.jjjshop.net/20231101092407827.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (129, '首页6', 3, 'https://qn-cdn.jjjshop.net/20231101091932955.png', 101, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (130, '订单5', 3, 'https://qn-cdn.jjjshop.net/20231101091931544.png', 102, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (131, '订单6', 3, 'https://qn-cdn.jjjshop.net/20231101091933514.png', 102, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (132, '购物车6', 3, 'https://qn-cdn.jjjshop.net/20231101091930997.png', 105, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (133, '我的5', 3, 'https://qn-cdn.jjjshop.net/20231101091934295.png', 106, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (134, '我的6', 3, 'https://qn-cdn.jjjshop.net/20231101091932330.png', 106, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (135, '收货地址', 2, 'https://qn-cdn.jjjshop.net/20231101092406119.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (136, '签到', 2, 'https://qn-cdn.jjjshop.net/20231101092405272.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (137, '申请入驻', 2, 'https://qn-cdn.jjjshop.net/20231101092403813.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (138, '我的收藏', 2, 'https://qn-cdn.jjjshop.net/20231101092404581.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (139, '我的钱包', 2, 'https://qn-cdn.jjjshop.net/20231101092402854.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (140, '我的礼包', 2, 'https://qn-cdn.jjjshop.net/20231101092401088.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (141, '设置', 2, 'https://qn-cdn.jjjshop.net/20231101092400791.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (142, '我的收藏', 2, 'https://qn-cdn.jjjshop.net/20231101092359742.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (143, '我的评价', 2, 'https://qn-cdn.jjjshop.net/20231101092358959.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (144, '我的钱包', 2, 'https://qn-cdn.jjjshop.net/20231101092357009.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (145, '领券中心', 2, 'https://qn-cdn.jjjshop.net/20231101092358076.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (146, '我的关注', 2, 'https://qn-cdn.jjjshop.net/20231101092358363.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (147, '收货地址', 2, 'https://qn-cdn.jjjshop.net/20231101092356297.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (148, '我的砍价', 2, 'https://qn-cdn.jjjshop.net/20231101092355619.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (149, '我的优惠券', 2, 'https://qn-cdn.jjjshop.net/20231101092354752.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (150, '我的签到', 2, 'https://qn-cdn.jjjshop.net/20231101092355045.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (151, '我的任务', 2, 'https://qn-cdn.jjjshop.net/20221224135102702.png', 100, 0, 1699516456, 1699516456);
INSERT INTO `zmodu_image_bank` VALUES (152, '我的转盘', 2, 'https://qn-cdn.jjjshop.net/20231101111032746.png', 100, 0, 1699516456, 1699516456);

-- ----------------------------
-- Table structure for zmodu_live_gift
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_live_gift`;
CREATE TABLE `zmodu_live_gift`  (
  `gift_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `gift_name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL COMMENT '礼物名称',
  `price` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '礼物价格',
  `is_hot` tinyint(4) NULL DEFAULT 0 COMMENT '是否热门0否1是',
  `is_active` tinyint(4) NULL DEFAULT 0 COMMENT '是否活动0否1是',
  `image_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '图片地址',
  `sort` int(11) NULL DEFAULT 100 COMMENT '排序，越小越前',
  `app_id` int(11) NULL DEFAULT 0 COMMENT '应用id',
  `is_delete` tinyint(4) NULL DEFAULT 0 COMMENT '是否删除0否1是',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  PRIMARY KEY (`gift_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '直播礼品表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_live_gift
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_live_plan
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_live_plan`;
CREATE TABLE `zmodu_live_plan`  (
  `plan_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `plan_name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '套餐名称',
  `money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '支付金额',
  `gift_money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '到账金额',
  `give_money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '赠送金额',
  `sort` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '排序(数字越小越靠前)',
  `is_delete` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否删除',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序商城id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`plan_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '礼物币充值表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_live_plan
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_live_plan_order
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_live_plan_order`;
CREATE TABLE `zmodu_live_plan_order`  (
  `order_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '订单id',
  `order_no` varchar(20) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '订单号',
  `user_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '用户id',
  `plan_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '套餐id',
  `plan_name` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '套餐名称',
  `pay_price` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '用户支付金额',
  `gift_money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '用户支付金额',
  `give_money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '用户支付金额',
  `total_money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '用户支付金额',
  `pay_status` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '支付状态(10待支付 20已支付)',
  `pay_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '付款时间',
  `transaction_id` varchar(30) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '微信支付交易号',
  `pay_source` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '支付来源,wx,android,ios',
  `pay_type` tinyint(4) NULL DEFAULT 20 COMMENT '支付方式(10余额支付 20微信支付 30支付宝)',
  `balance` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '余额抵扣金额',
  `online_money` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '在线支付金额',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序商城id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`order_id`) USING BTREE,
  UNIQUE INDEX `order_no`(`order_no`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '礼物币充值订单表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_live_plan_order
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_live_product
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_live_product`;
CREATE TABLE `zmodu_live_product`  (
  `live_product_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `user_id` int(10) UNSIGNED NOT NULL COMMENT '会员id',
  `product_id` int(10) UNSIGNED NOT NULL COMMENT '商品id',
  `shop_supplier_id` int(11) NOT NULL DEFAULT 0 COMMENT '供应商id',
  `app_id` int(11) NULL DEFAULT 0 COMMENT 'appid',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  PRIMARY KEY (`live_product_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '直播房间商品表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_live_product
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_live_room
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_live_room`;
CREATE TABLE `zmodu_live_room`  (
  `room_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `user_id` int(11) NULL DEFAULT 0 COMMENT '用户id',
  `name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '直播间名称',
  `room_name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '直播间名称，第三方',
  `cover_img_id` int(11) NULL DEFAULT 0 COMMENT '直播间背景图链接',
  `share_img_id` int(11) NULL DEFAULT 0 COMMENT '直播间分享图链接',
  `live_status` tinyint(3) UNSIGNED NOT NULL DEFAULT 102 COMMENT '直播间状态。0待审核100未通过，101：直播中，102：未开始，103已结束，104：暂停，107：已过期',
  `anchor_name` varchar(30) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '主播名',
  `start_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '直播间开始时间',
  `end_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '直播计划结束时间',
  `real_start_time` int(11) NULL DEFAULT 0 COMMENT '时间开始时间',
  `real_end_time` int(11) NULL DEFAULT 0 COMMENT '实际结束时间',
  `sort` int(11) NULL DEFAULT 100 COMMENT '排序，值越小越靠前',
  `is_top` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '置顶状态(0未置顶 1已置顶)',
  `view_num` int(11) NULL DEFAULT 0 COMMENT '观看人数',
  `gift_num` int(11) NULL DEFAULT 0 COMMENT '礼物数',
  `sales_num` int(11) NULL DEFAULT 0 COMMENT '卖出商品数，件',
  `digg_num` int(11) NULL DEFAULT 0 COMMENT '点赞数',
  `product_id` int(11) NULL DEFAULT 0 COMMENT '当前讲解商品',
  `virtual_num` int(11) NULL DEFAULT 0 COMMENT '虚拟人数',
  `is_notice` tinyint(4) NULL DEFAULT 0 COMMENT '是否预告，0否1是',
  `shop_supplier_id` int(11) NOT NULL DEFAULT 0 COMMENT '供应商id',
  `audit_remark` varchar(100) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '审核备注',
  `category_id` int(11) NOT NULL COMMENT '主营分类id',
  `record_uid` int(11) NULL DEFAULT 0 COMMENT '录制uid',
  `record_resource_id` varchar(1000) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '录制资源id',
  `record_sid` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '录制sid',
  `record_url` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '录制文件名',
  `app_id` int(11) NULL DEFAULT 0 COMMENT '应用id',
  `is_delete` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '软删除(0未删除 1已删除)',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`room_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '直播房间表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_live_room
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_live_room_gift
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_live_room_gift`;
CREATE TABLE `zmodu_live_room_gift`  (
  `room_gift_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `room_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '房间id',
  `user_id` int(11) NULL DEFAULT 0 COMMENT '用户id',
  `gift_name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '礼物名称',
  `price` int(11) NULL DEFAULT 0 COMMENT '总价格，没有小数',
  `shop_supplier_id` int(11) NOT NULL DEFAULT 0 COMMENT '供应商id',
  `app_id` int(11) NULL DEFAULT 0 COMMENT '应用id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  PRIMARY KEY (`room_gift_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '直播房间礼品表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_live_room_gift
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_live_user_gift
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_live_user_gift`;
CREATE TABLE `zmodu_live_user_gift`  (
  `user_gift_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `room_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '房间id',
  `user_id` int(11) NULL DEFAULT 0 COMMENT '用户id',
  `gift_num` int(11) NULL DEFAULT 0 COMMENT '礼物币数量',
  `shop_supplier_id` int(11) NOT NULL DEFAULT 0 COMMENT '供应商id',
  `app_id` int(11) NULL DEFAULT 0 COMMENT '应用id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  PRIMARY KEY (`user_gift_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '直播房间用户礼物表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_live_user_gift
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_lottery
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_lottery`;
CREATE TABLE `zmodu_lottery`  (
  `lottery_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'ID',
  `times` int(11) NOT NULL DEFAULT 0 COMMENT '每日抽奖次数',
  `points` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '抽奖积分',
  `total_num` int(11) NOT NULL DEFAULT 0 COMMENT '抽奖次数',
  `status` tinyint(4) NOT NULL DEFAULT 0 COMMENT '状态0关闭1开启',
  `image_id` int(11) NOT NULL DEFAULT 0 COMMENT '背景图',
  `content` longtext CHARACTER SET utf8 COLLATE utf8_general_ci NULL COMMENT '抽奖规则',
  `type` tinyint(3) NOT NULL DEFAULT 0 COMMENT '抽奖类型0九宫格,1大转盘',
  `user_type` tinyint(3) NOT NULL DEFAULT 0 COMMENT '参与用户类型0全部用户,1部分用户',
  `grades` text CHARACTER SET utf8 COLLATE utf8_general_ci NULL COMMENT '用户等级ID',
  `start_time` int(11) NOT NULL DEFAULT 0 COMMENT '开始时间',
  `end_time` int(11) NOT NULL DEFAULT 0 COMMENT '结束时间',
  `is_delete` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否删除',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`lottery_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '抽奖设置表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_lottery
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_lottery_prize
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_lottery_prize`;
CREATE TABLE `zmodu_lottery_prize`  (
  `prize_id` int(11) NOT NULL AUTO_INCREMENT COMMENT '奖项id',
  `lottery_id` int(11) NOT NULL DEFAULT 0 COMMENT '抽奖id',
  `name` varchar(100) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL DEFAULT '' COMMENT '奖项名称',
  `stock` int(10) NOT NULL DEFAULT 0 COMMENT '总库存',
  `draw_num` int(11) NOT NULL DEFAULT 0 COMMENT '已抽奖数量',
  `type` tinyint(2) NOT NULL DEFAULT 0 COMMENT '奖项类型0无奖品1优惠券2积分3商品4余额',
  `image` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NULL DEFAULT '' COMMENT '奖品图片',
  `is_default` tinyint(1) NOT NULL DEFAULT 0 COMMENT '是否默认奖项0否1是',
  `award_id` int(11) NOT NULL DEFAULT 0 COMMENT '商品优惠券id',
  `status` tinyint(4) NOT NULL DEFAULT 10 COMMENT '10上架20下架',
  `points` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '积分',
  `is_play` tinyint(1) NOT NULL DEFAULT 0 COMMENT '是否播报0否1是',
  `weight` int(11) NOT NULL DEFAULT 0 COMMENT '奖品权重',
  `probability` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '奖品概率',
  `prompt` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL DEFAULT '' COMMENT '提示语',
  `balance` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '余额',
  `product_price` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '商品价格',
  `sort` int(10) NOT NULL DEFAULT 0 COMMENT '排序',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`prize_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8mb4 COLLATE = utf8mb4_general_ci COMMENT = '奖项' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_lottery_prize
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_lottery_record
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_lottery_record`;
CREATE TABLE `zmodu_lottery_record`  (
  `record_id` int(11) NOT NULL AUTO_INCREMENT,
  `record_name` varchar(120) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL DEFAULT '' COMMENT '中奖名称',
  `user_id` int(11) NOT NULL DEFAULT 0 COMMENT '会员id',
  `prize_type` tinyint(1) NOT NULL DEFAULT 0 COMMENT '0无礼品1优惠券2积分3商品4余额',
  `award_id` int(11) NOT NULL DEFAULT 0 COMMENT '奖品id（商品id，优惠券id）',
  `status` tinyint(1) NOT NULL DEFAULT 0 COMMENT '是否使用0否1是',
  `prize_num` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '奖品数量',
  `prize_id` int(11) NOT NULL DEFAULT 0 COMMENT '奖项id',
  `is_play` tinyint(1) NOT NULL DEFAULT 0 COMMENT '是否播报0否1是',
  `image` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NULL DEFAULT '' COMMENT '奖品图片',
  `name` varchar(30) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '收货人姓名',
  `phone` varchar(20) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '联系电话',
  `province_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '所在省份id',
  `city_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '所在城市id',
  `region_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '所在区id',
  `detail` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '详细地址',
  `express_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '物流公司id',
  `express_no` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '物流单号',
  `delivery_status` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '发货状态(10未发货 20已发货)',
  `delivery_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '发货时间',
  `remark` text CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NULL COMMENT '备注',
  `product_price` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '商品价格',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`record_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8mb4 COLLATE = utf8mb4_general_ci COMMENT = '抽奖记录' ROW_FORMAT = DYNAMIC;

-- ----------------------------
-- Records of zmodu_lottery_record
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_message
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_message`;
CREATE TABLE `zmodu_message`  (
  `message_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '消息id',
  `message_name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '消息名称',
  `message_ename` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '消息英文名',
  `message_to` tinyint(4) NULL DEFAULT 10 COMMENT '通知对象,10会员20,商家30,供应商',
  `message_type` tinyint(4) NULL DEFAULT 10 COMMENT '消息类别,10订单20分销30通知',
  `remark` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '描述',
  `sort` int(11) NULL DEFAULT 100 COMMENT '消息排序',
  `is_delete` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '0,否1,是',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`message_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 9 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '应用消息表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_message
-- ----------------------------
INSERT INTO `zmodu_message` VALUES (1, '支付成功', 'order_pay_user', 10, 10, '支付成功通知', 100, 0, 1575718491, 1586418652);
INSERT INTO `zmodu_message` VALUES (3, '发货通知', 'order_delivery_user', 10, 10, '订单发货通知', 100, 0, 1576911963, 1576913619);
INSERT INTO `zmodu_message` VALUES (4, '订单售后通知', 'order_refund_user', 10, 10, '订单售后通知', 100, 0, 1576913450, 1576913627);
INSERT INTO `zmodu_message` VALUES (5, '分销商审核通知', 'agent_apply_user', 10, 20, '分销商审核通知', 100, 0, 1576914765, 1588391117);
INSERT INTO `zmodu_message` VALUES (6, '分销商提现通知', 'agent_cash_user', 10, 20, '分销商提现通知', 100, 0, 1576915900, 1588390764);
INSERT INTO `zmodu_message` VALUES (7, '新订单商家通知', 'order_pay_store', 20, 10, '新订单商家通知', 100, 0, 1576919415, 1576919415);
INSERT INTO `zmodu_message` VALUES (8, '新消息通知', 'supplier_new_message', 30, 30, '新消息通知', 100, 0, 1609740641, 1609740641);

-- ----------------------------
-- Table structure for zmodu_message_field
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_message_field`;
CREATE TABLE `zmodu_message_field`  (
  `message_field_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '字段id',
  `message_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '消息id',
  `field_name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '字段名称',
  `field_ename` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '字段英文名',
  `filed_value` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '字段默认',
  `is_var` tinyint(4) NULL DEFAULT 0 COMMENT '是否变量.0,否,1是',
  `sort` int(11) NULL DEFAULT 100 COMMENT '字段排序',
  `is_delete` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否删除',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`message_field_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 68 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '应用消息字段表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_message_field
-- ----------------------------
INSERT INTO `zmodu_message_field` VALUES (6, 1, '订单编号', 'order_no', '', 1, 2, 0, 1575807724, 1575961064);
INSERT INTO `zmodu_message_field` VALUES (7, 1, '支付时间', 'pay_time', '', 1, 6, 0, 1575807724, 1575961064);
INSERT INTO `zmodu_message_field` VALUES (10, 1, '订单金额', 'pay_price', '', 1, 4, 0, 1575807799, 1575961064);
INSERT INTO `zmodu_message_field` VALUES (11, 1, '商品名称', 'product_name', '', 1, 3, 0, 1575807799, 1575961064);
INSERT INTO `zmodu_message_field` VALUES (15, 1, '通知标题', 'first', '亲，您的订单已支付成功', 0, 1, 0, 1575811846, 1575961064);
INSERT INTO `zmodu_message_field` VALUES (16, 1, '备注', 'remark', '感谢您使用我们的服务', 0, 7, 0, 1575812040, 1575961064);
INSERT INTO `zmodu_message_field` VALUES (17, 1, '支付方式', 'pay_type', '', 1, 5, 0, 1575812040, 1575961064);
INSERT INTO `zmodu_message_field` VALUES (18, 3, '订单号', 'order_no', '', 1, 2, 0, 1576912186, 1592835444);
INSERT INTO `zmodu_message_field` VALUES (19, 3, '商品名称', 'product_name', '', 1, 3, 0, 1576912186, 1592835444);
INSERT INTO `zmodu_message_field` VALUES (20, 3, '收货人', 'name', '', 1, 4, 0, 1576912186, 1592835444);
INSERT INTO `zmodu_message_field` VALUES (21, 3, '收货地址', 'address', '', 1, 5, 0, 1576912186, 1592835444);
INSERT INTO `zmodu_message_field` VALUES (22, 3, '物流公司', 'express_name', '', 1, 6, 0, 1576912186, 1592835444);
INSERT INTO `zmodu_message_field` VALUES (23, 3, '物流单号', 'express_no', '', 1, 7, 0, 1576912186, 1592835444);
INSERT INTO `zmodu_message_field` VALUES (24, 3, '备注', 'remark', '感谢您使用我们的服务', 0, 100, 0, 1576912186, 1592835444);
INSERT INTO `zmodu_message_field` VALUES (25, 3, '通知标题', 'title', '亲，您的订单已发货', 0, 1, 0, 1576912246, 1592835444);
INSERT INTO `zmodu_message_field` VALUES (26, 4, '通知标题', 'title', '订单售后通知', 0, 1, 0, 1576913821, 1592876603);
INSERT INTO `zmodu_message_field` VALUES (27, 4, '售后类型', 'type', '', 1, 4, 0, 1576913821, 1592876603);
INSERT INTO `zmodu_message_field` VALUES (28, 4, '处理结果', 'status', '', 1, 5, 0, 1576913821, 1592876603);
INSERT INTO `zmodu_message_field` VALUES (29, 4, '订单号', 'order_no', '', 1, 2, 0, 1576913821, 1592876603);
INSERT INTO `zmodu_message_field` VALUES (30, 4, '商品名称', 'product_name', '', 1, 3, 0, 1576913821, 1592876603);
INSERT INTO `zmodu_message_field` VALUES (31, 4, '处理时间', 'process_time', '', 1, 6, 0, 1576913821, 1592876603);
INSERT INTO `zmodu_message_field` VALUES (32, 4, '拒绝原因', 'refuse_desc', '', 1, 7, 0, 1576913821, 1592876603);
INSERT INTO `zmodu_message_field` VALUES (33, 4, '备注', 'remark', '亲，您的售后订单有新的动态', 0, 100, 0, 1576913821, 1592876603);
INSERT INTO `zmodu_message_field` VALUES (34, 5, '通知标题', 'title', '分销审核结果', 0, 100, 0, 1576915005, 1576915005);
INSERT INTO `zmodu_message_field` VALUES (35, 5, '申请时间', 'apply_time', '', 1, 100, 0, 1576915005, 1576915005);
INSERT INTO `zmodu_message_field` VALUES (36, 5, '审核状态', 'apply_status', '', 1, 100, 0, 1576915005, 1576915005);
INSERT INTO `zmodu_message_field` VALUES (37, 5, '审核时间', 'audit_time', '', 1, 100, 0, 1576915005, 1576915005);
INSERT INTO `zmodu_message_field` VALUES (38, 5, '拒绝原因', 'reason', '', 1, 100, 0, 1576915005, 1576915005);
INSERT INTO `zmodu_message_field` VALUES (39, 5, '备注', 'remark', '分销审核结果通知 ', 0, 100, 0, 1576915005, 1576915005);
INSERT INTO `zmodu_message_field` VALUES (40, 6, '通知标题', 'title', '', 0, 100, 0, 1576916216, 1576916216);
INSERT INTO `zmodu_message_field` VALUES (41, 6, '提现时间', 'create_time', '', 1, 100, 0, 1576916216, 1576916216);
INSERT INTO `zmodu_message_field` VALUES (42, 6, '提现方式', 'pay_type', '', 1, 100, 0, 1576916216, 1576916216);
INSERT INTO `zmodu_message_field` VALUES (43, 6, '提现金额', 'money', '', 1, 100, 0, 1576916216, 1576916216);
INSERT INTO `zmodu_message_field` VALUES (44, 6, '提现状态', 'apply_status', '', 1, 100, 0, 1576916216, 1576916216);
INSERT INTO `zmodu_message_field` VALUES (45, 6, '拒绝原因', 'reason', '', 1, 100, 0, 1576916216, 1576916216);
INSERT INTO `zmodu_message_field` VALUES (46, 6, '备注', 'remark', '', 0, 100, 0, 1576916217, 1576916217);
INSERT INTO `zmodu_message_field` VALUES (47, 7, '订单编号', 'order_no', '', 1, 2, 0, 1575807724, 1576919570);
INSERT INTO `zmodu_message_field` VALUES (48, 7, '支付时间', 'pay_time', '', 1, 6, 0, 1575807724, 1576919570);
INSERT INTO `zmodu_message_field` VALUES (49, 7, '订单金额', 'pay_price', '', 1, 4, 0, 1575807799, 1576919570);
INSERT INTO `zmodu_message_field` VALUES (50, 7, '商品名称', 'product_name', '', 1, 3, 0, 1575807799, 1576919570);
INSERT INTO `zmodu_message_field` VALUES (51, 7, '通知标题', 'first', '亲，您的订单已支付成功', 0, 1, 1, 1575811846, 1575961064);
INSERT INTO `zmodu_message_field` VALUES (52, 7, '备注', 'remark', '感谢您使用我们的服务', 0, 7, 1, 1575812040, 1575961064);
INSERT INTO `zmodu_message_field` VALUES (63, 3, '发货时间', 'express_time', '', 1, 8, 0, 1592835444, 1592835444);
INSERT INTO `zmodu_message_field` VALUES (64, 8, '商家名称', 'name', '', 1, 1, 0, 1609741190, 1609741331);
INSERT INTO `zmodu_message_field` VALUES (65, 8, '订单号', 'order_no', '', 1, 2, 0, 1609741219, 1609741331);
INSERT INTO `zmodu_message_field` VALUES (66, 8, '下单时间', 'create_time', '', 1, 3, 0, 1609741239, 1609741331);
INSERT INTO `zmodu_message_field` VALUES (67, 8, '备注', 'remark', '查看更多未处理消息', 0, 100, 0, 1609741307, 1609741331);

-- ----------------------------
-- Table structure for zmodu_message_settings
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_message_settings`;
CREATE TABLE `zmodu_message_settings`  (
  `message_settings_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '设置id',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '应用id',
  `message_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '消息id',
  `sms_status` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '0,未开启,1开启',
  `sms_template` text CHARACTER SET utf8 COLLATE utf8_general_ci NULL COMMENT '短信模板(json)',
  `mp_status` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '0,未开启,1开启',
  `mp_template` text CHARACTER SET utf8 COLLATE utf8_general_ci NULL COMMENT '微信公众号模板(json)',
  `wx_status` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '0,未开启,1开启',
  `wx_template` text CHARACTER SET utf8 COLLATE utf8_general_ci NULL COMMENT '微信小程序模板(json)',
  `mt_status` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '公众号模板消息状态0,未开启,1开启',
  `mt_template` text CHARACTER SET utf8 COLLATE utf8_general_ci NULL COMMENT '微信公众号模板(json)',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`message_settings_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '应用消息设置表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_message_settings
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_order
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_order`;
CREATE TABLE `zmodu_order`  (
  `order_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '订单id',
  `order_no` varchar(20) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '订单号',
  `total_price` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '商品总金额(不含优惠折扣)',
  `order_price` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '订单金额(含优惠折扣)',
  `coupon_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '优惠券id',
  `coupon_money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '优惠券抵扣金额',
  `coupon_id_sys` int(11) NULL DEFAULT 0 COMMENT '系统优惠券',
  `coupon_money_sys` decimal(10, 2) NULL DEFAULT 0.00 COMMENT '平台优惠券抵扣',
  `points_money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '积分抵扣金额',
  `points_num` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '积分抵扣数量',
  `pay_price` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '实际付款金额(包含运费)',
  `update_price` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '后台修改的订单金额（差价）',
  `fullreduce_money` double(10, 2) NULL DEFAULT 0.00 COMMENT '满减金额',
  `fullreduce_remark` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '满减备注',
  `product_reduce_money` decimal(10, 2) NULL DEFAULT 0.00 COMMENT '商品满减总额',
  `buyer_remark` mediumtext CHARACTER SET utf8 COLLATE utf8_general_ci NULL COMMENT '买家留言',
  `pay_type` tinyint(3) UNSIGNED NOT NULL DEFAULT 20 COMMENT '支付方式(10余额支付 20微信支付)',
  `pay_source` varchar(20) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '支付来源,mp,wx',
  `pay_status` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '付款状态(10未付款 20已付款)',
  `pay_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '付款时间',
  `pay_end_time` int(11) NULL DEFAULT 0 COMMENT '支付截止时间',
  `delivery_type` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '配送方式(10快递配送 20上门自提 30无需物流)',
  `extract_store_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '自提门店id',
  `extract_clerk_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '核销店员id',
  `express_price` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '运费金额',
  `express_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '物流公司id',
  `express_company` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '物流公司',
  `express_no` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '物流单号',
  `delivery_status` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '发货状态(10未发货 20全部发货 30部分发货)',
  `delivery_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '发货时间',
  `receipt_status` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '收货状态(10未收货 20已收货)',
  `receipt_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '收货时间',
  `order_status` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '订单状态10=>进行中，20=>已经取消，30=>已完成',
  `points_bonus` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '赠送的积分数量',
  `is_settled` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '订单是否已结算(0未结算 1已结算)',
  `transaction_id` varchar(30) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '微信支付交易号',
  `is_comment` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否已评价(0否 1是)',
  `order_source` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '订单来源(10普通 20积分 30拼团 40砍价 50秒杀 60礼包购)',
  `user_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '用户id',
  `is_refund` tinyint(4) NULL DEFAULT 0 COMMENT '拼团等活动失败退款',
  `assemble_status` tinyint(4) NULL DEFAULT 0 COMMENT '拼团状态 10拼单中 20拼单成功 30拼单失败',
  `activity_id` int(11) NULL DEFAULT 0 COMMENT '活动id，对应拼团，秒杀，砍价活动id',
  `is_agent` tinyint(4) NULL DEFAULT 0 COMMENT '是否可以分销0否1是',
  `shop_supplier_id` int(11) NULL DEFAULT 0 COMMENT '供应商id',
  `supplier_money` decimal(10, 2) NULL DEFAULT 0.00 COMMENT '供应商结算金额,支付金额-平台结算金额',
  `sys_money` decimal(10, 2) NULL DEFAULT 0.00 COMMENT '平台结算金额',
  `room_id` int(11) NULL DEFAULT 0 COMMENT '直播间id',
  `cancel_remark` varchar(200) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '商家取消订单备注',
  `virtual_auto` tinyint(4) NOT NULL DEFAULT 0 COMMENT '是否自动发货1自动0手动',
  `virtual_content` longtext CHARACTER SET utf8 COLLATE utf8_general_ci NULL COMMENT '虚拟物品内容',
  `balance` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '余额抵扣金额',
  `online_money` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '在线支付金额',
  `refund_money` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '退款金额',
  `trade_no` varchar(20) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '支付订单号',
  `wx_delivery_status` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '微信发货状态(10未发货 20已发货)',
  `is_single` tinyint(4) NULL DEFAULT 0 COMMENT '发货类型0单包裹1多包裹',
  `task_id` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '电子面单任务ID',
  `return_num` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '电子面单回单号',
  `label` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '电子面单短链，printType为IMAGE或者HTML时的面单短链',
  `kd_order_num` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '电子面单订单号',
  `is_label` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否电子面单发货，0不是，1是',
  `label_print_type` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '电子面单打印方式，0本地打印，1快递100云打印',
  `template_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '面单模板id',
  `setting_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '面单设置id',
  `address_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '发货地址id',
  `custom_form` longtext CHARACTER SET utf8 COLLATE utf8_general_ci NULL COMMENT '自定义表单信息',
  `delete_time` int(11) UNSIGNED NOT NULL DEFAULT 0 COMMENT '删除时间',
  `is_delete` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否删除',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`order_id`) USING BTREE,
  UNIQUE INDEX `order_no`(`order_no`) USING BTREE,
  UNIQUE INDEX `trade_no`(`trade_no`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '订单记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_order
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_order_address
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_order_address`;
CREATE TABLE `zmodu_order_address`  (
  `order_address_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '地址id',
  `name` varchar(30) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '收货人姓名',
  `phone` varchar(20) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '联系电话',
  `province_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '所在省份id',
  `city_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '所在城市id',
  `region_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '所在区id',
  `detail` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '详细地址',
  `order_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '订单id',
  `user_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '用户id',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  PRIMARY KEY (`order_address_id`) USING BTREE,
  INDEX `order_id`(`order_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '订单收货地址记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_order_address
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_order_advance
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_order_advance`;
CREATE TABLE `zmodu_order_advance`  (
  `order_advance_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT ' 主键id',
  `advance_product_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '预售商品id',
  `advance_product_sku_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '预售商品规格id',
  `user_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '用户id',
  `end_time` int(11) NOT NULL DEFAULT 0 COMMENT '预售结束时间',
  `order_no` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '订单号',
  `pay_price` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '支付定金金额',
  `pay_type` tinyint(3) UNSIGNED NOT NULL DEFAULT 20 COMMENT '支付方式(10余额支付 20微信支付30支付宝)',
  `balance` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '余额抵扣金额',
  `online_money` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '在线支付金额',
  `pay_status` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '付款状态(10未付款 20已付款)',
  `pay_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '付款时间',
  `order_status` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '订单状态10=>进行中，20=>已经取消，30=>已完成',
  `pay_end_time` int(11) NULL DEFAULT 0 COMMENT '预售订单支付结束时间',
  `order_id` int(11) NOT NULL DEFAULT 0 COMMENT '主订单id',
  `pay_source` varchar(20) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '支付来源,mp,wx',
  `money_return` tinyint(1) NOT NULL DEFAULT 0 COMMENT '是否允许退款0不允许1允许',
  `refund_money` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '退款金额',
  `reduce_money` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '尾款立减金额',
  `main_order_no` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '主订单号',
  `is_refund` tinyint(1) NOT NULL DEFAULT 0 COMMENT '是否已退款0否1是',
  `shop_supplier_id` int(11) NOT NULL DEFAULT 0 COMMENT '供应商id',
  `transaction_id` varchar(30) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '微信支付交易号',
  `trade_no` varchar(20) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '支付订单号',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT 'app_id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`order_advance_id`) USING BTREE,
  UNIQUE INDEX `order_no`(`order_no`) USING BTREE,
  UNIQUE INDEX `trade_no`(`trade_no`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '预售定金订单记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_order_advance
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_order_delivery
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_order_delivery`;
CREATE TABLE `zmodu_order_delivery`  (
  `order_delivery_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '订单物流id',
  `order_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '订单id',
  `express_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '物流公司id',
  `express_no` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '物流单号',
  `task_id` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '电子面单任务ID',
  `return_num` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '电子面单回单号',
  `label` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '电子面单短链，printType为IMAGE或者HTML时的面单短链',
  `kd_order_num` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '电子面单订单号',
  `is_label` tinyint(4) NULL DEFAULT 0 COMMENT '是否电子面单发货，0不是，1是',
  `label_print_type` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '电子面单打印方式，0本地打印，1快递100云打印',
  `setting_id` int(11) NULL DEFAULT 0 COMMENT '面单设置ID',
  `template_id` int(11) NULL DEFAULT 0 COMMENT '电子面单模板ID',
  `address_id` int(11) NULL DEFAULT 0 COMMENT '发货地址ID',
  `remark` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '备注',
  `delivery_data` longtext CHARACTER SET utf8 COLLATE utf8_general_ci NULL COMMENT '物流商品信息json格式，如商品id和数量',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '应用id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`order_delivery_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '订单物流表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_order_delivery
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_order_extract
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_order_extract`;
CREATE TABLE `zmodu_order_extract`  (
  `id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `order_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '订单id',
  `linkman` varchar(30) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '联系人姓名',
  `phone` varchar(20) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '联系电话',
  `user_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '用户id',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  PRIMARY KEY (`id`) USING BTREE,
  INDEX `order_id`(`order_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '自提订单联系方式记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_order_extract
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_order_product
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_order_product`;
CREATE TABLE `zmodu_order_product`  (
  `order_product_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `product_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '商品id',
  `product_name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '商品名称',
  `image_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '商品封面图id',
  `deduct_stock_type` tinyint(3) UNSIGNED NOT NULL DEFAULT 20 COMMENT '库存计算方式(10下单减库存 20付款减库存)',
  `spec_type` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '规格类型(10单规格 20多规格)',
  `spec_sku_id` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '商品sku标识',
  `product_sku_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '商品规格id',
  `product_attr` varchar(500) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '商品规格信息',
  `content` longtext CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL COMMENT '商品详情',
  `product_no` varchar(100) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '商品编码',
  `product_price` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '商品价格(单价)',
  `line_price` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '商品划线价',
  `product_weight` double UNSIGNED NOT NULL DEFAULT 0 COMMENT '商品重量(Kg)',
  `is_user_grade` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否存在会员等级折扣',
  `grade_ratio` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '会员折扣比例(0-10)',
  `grade_product_price` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '会员折扣的商品单价',
  `grade_total_money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '会员折扣的总额差',
  `coupon_money_sys` decimal(10, 2) NULL DEFAULT 0.00 COMMENT '平台优惠券抵扣',
  `coupon_money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '优惠券折扣金额',
  `points_money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '积分金额',
  `points_num` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '积分抵扣数量',
  `points_bonus` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '赠送的积分数量',
  `total_num` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '购买数量',
  `total_price` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '商品总价(数量×单价)',
  `total_pay_price` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '实际付款价(折扣和优惠后)',
  `supplier_money` decimal(10, 2) NULL DEFAULT 0.00 COMMENT '供应商金额',
  `sys_money` decimal(10, 2) NULL DEFAULT 0.00 COMMENT '平台结算金额',
  `fullreduce_money` decimal(10, 2) NULL DEFAULT 0.00 COMMENT '满减金额',
  `product_reduce_money` decimal(10, 2) NULL DEFAULT 0.00 COMMENT '商品满减金额',
  `is_agent` tinyint(4) NULL DEFAULT 0 COMMENT '是否开启分销0否1是',
  `is_ind_agent` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否开启单独分销(0关闭 1开启)',
  `agent_money_type` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '分销佣金类型(10百分比 20固定金额)',
  `first_money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '分销佣金(一级)',
  `second_money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '分销佣金(二级)',
  `third_money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '分销佣金(三级)',
  `is_comment` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否已评价(0否 1是)',
  `order_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '订单id',
  `user_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '用户id',
  `product_source_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '来源商品记录id',
  `sku_source_id` int(11) NULL DEFAULT 0 COMMENT '来源商品sku id',
  `bill_source_id` int(11) NULL DEFAULT 0 COMMENT '拼团等的拼团订单id',
  `virtual_content` varchar(200) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '虚拟物品内容',
  `delivery_num` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '已发货总数量',
  `is_gift` tinyint(3) NOT NULL DEFAULT 0 COMMENT '赠品类型1买送',
  `agent_first_money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '分销获取佣金(一级)',
  `agent_second_money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '分销获取佣金(二级)',
  `product_type` tinyint(3) NOT NULL DEFAULT 1 COMMENT '商品类型1普通商品2虚拟商品3卡密商品4次卡商品',
  `card_type` tinyint(3) NOT NULL DEFAULT 10 COMMENT '卡密类型10固定卡密20一次性卡密',
  `verify_num` int(11) NOT NULL DEFAULT 0 COMMENT '核销次数',
  `valid_type` tinyint(3) NOT NULL DEFAULT 10 COMMENT '核销有效期10永久20购买后几天内有效30固定日期',
  `valid_day` int(11) NOT NULL DEFAULT 0 COMMENT '购买后天数',
  `valid_start_time` int(11) NOT NULL DEFAULT 0 COMMENT '开始时间',
  `valid_end_time` int(11) NOT NULL DEFAULT 0 COMMENT '结束时间',
  `use_verify_num` int(11) UNSIGNED NOT NULL DEFAULT 0 COMMENT '已使用核销次数',
  `refund_status` tinyint(3) NOT NULL DEFAULT 0 COMMENT '是否支持退款0否1是',
  `overdue_refund_status` tinyint(3) NOT NULL DEFAULT 0 COMMENT '过期支持退款0否1是',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  PRIMARY KEY (`order_product_id`) USING BTREE,
  INDEX `order_id`(`order_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '订单商品记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_order_product
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_order_refund
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_order_refund`;
CREATE TABLE `zmodu_order_refund`  (
  `order_refund_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '售后单id',
  `order_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '订单id',
  `order_product_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '订单商品id',
  `user_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '用户id',
  `type` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '售后类型(10退货退款 20换货 30退款)',
  `apply_desc` varchar(1000) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '用户申请原因(说明)',
  `is_agree` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '商家审核状态(0待审核 10已同意 20已拒绝)',
  `refuse_desc` varchar(1000) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '商家拒绝原因(说明)',
  `refund_money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '实际退款金额',
  `is_user_send` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '用户是否发货(0未发货 1已发货)',
  `send_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '用户发货时间',
  `express_id` varchar(32) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '用户发货物流公司id',
  `express_no` varchar(32) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '用户发货物流单号',
  `is_receipt` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '商家收货状态(0未收货 1已收货)',
  `status` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '售后单状态(0进行中 10已拒绝 20已完成 30已取消)',
  `deliver_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '平台发货时间',
  `send_express_id` varchar(32) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '平台发货物流公司id',
  `send_express_no` varchar(32) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '平台发货物流单号',
  `is_plate_send` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '平台是否发货(0未发货 1已发货)',
  `shop_supplier_id` int(11) NULL DEFAULT 0 COMMENT '供应商id',
  `plate_status` tinyint(4) NOT NULL DEFAULT 0 COMMENT '10申请平台介入20同意30拒绝',
  `plate_desc` varchar(1000) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '平台备注',
  `out_refund_no` varchar(20) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '退款号',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`order_refund_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '售后单记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_order_refund
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_order_refund_address
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_order_refund_address`;
CREATE TABLE `zmodu_order_refund_address`  (
  `id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `order_refund_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '售后单id',
  `name` varchar(30) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '收货人姓名',
  `phone` varchar(20) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '联系电话',
  `detail` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '详细地址',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  PRIMARY KEY (`id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '售后单退货地址记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_order_refund_address
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_order_refund_image
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_order_refund_image`;
CREATE TABLE `zmodu_order_refund_image`  (
  `id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `order_refund_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '售后单id',
  `image_id` int(11) NOT NULL DEFAULT 0 COMMENT '图片id(关联文件记录表)',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  PRIMARY KEY (`id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '售后单图片记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_order_refund_image
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_order_settled
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_order_settled`;
CREATE TABLE `zmodu_order_settled`  (
  `settled_id` int(11) NOT NULL AUTO_INCREMENT,
  `order_id` int(11) NULL DEFAULT 0 COMMENT '订单号',
  `shop_supplier_id` int(11) NULL DEFAULT 0 COMMENT '供应商id',
  `order_money` decimal(10, 2) NULL DEFAULT 0.00 COMMENT '订单金额，不包括运费',
  `pay_money` decimal(10, 2) NULL DEFAULT 0.00 COMMENT '支付金额',
  `express_money` decimal(10, 2) NULL DEFAULT 0.00 COMMENT '运费',
  `supplier_money` decimal(10, 2) NULL DEFAULT 0.00 COMMENT '店铺金额',
  `real_supplier_money` decimal(10, 2) NULL DEFAULT 0.00 COMMENT '供应商实际结算金额',
  `sys_money` decimal(10, 2) NULL DEFAULT 0.00 COMMENT '平台抽成',
  `real_sys_money` decimal(10, 2) NULL DEFAULT 0.00 COMMENT '平台实际结算金额',
  `agent_total_money` decimal(10, 2) NULL DEFAULT 0.00 COMMENT '原分销佣金',
  `agent_money` decimal(10, 2) NULL DEFAULT 0.00 COMMENT '实际分销佣金',
  `refund_money` decimal(10, 2) NULL DEFAULT 0.00 COMMENT '退款金额',
  `refund_supplier_money` decimal(10, 2) NULL DEFAULT 0.00 COMMENT '供应商退款金额',
  `refund_sys_money` decimal(10, 2) NULL DEFAULT 0.00 COMMENT '平台退款结算金额',
  `app_id` int(11) NULL DEFAULT 0 COMMENT '应用id',
  `create_time` int(11) NULL DEFAULT NULL,
  PRIMARY KEY (`settled_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '订单结算表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_order_settled
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_order_trade
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_order_trade`;
CREATE TABLE `zmodu_order_trade`  (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `out_trade_no` varchar(20) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '0' COMMENT '外部交易号',
  `order_id` int(11) NULL DEFAULT 0 COMMENT '订单号',
  `create_time` int(11) NULL DEFAULT NULL,
  `update_time` int(11) NULL DEFAULT NULL,
  `app_id` int(11) NULL DEFAULT 0,
  `pay_status` tinyint(4) NULL DEFAULT 10 COMMENT '支付状态10,未支付,20已支付',
  `pay_time` int(11) NULL DEFAULT 0 COMMENT '支付时间',
  `balance` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '余额抵扣金额',
  `online_money` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '在线支付金额',
  PRIMARY KEY (`id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '外部交易号跟内部订单对应关系表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_order_trade
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_page
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_page`;
CREATE TABLE `zmodu_page`  (
  `page_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '页面id',
  `page_type` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '页面类型(10首页 20自定义页)',
  `page_name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '页面名称',
  `page_data` longtext CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL COMMENT '页面数据',
  `is_default` tinyint(1) NOT NULL DEFAULT 0 COMMENT '是否设置首页1是',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT 'appid',
  `is_delete` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '软删除',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`page_id`) USING BTREE,
  INDEX `app_id`(`app_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = 'diy页面表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_page
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_page_category
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_page_category`;
CREATE TABLE `zmodu_page_category`  (
  `app_id` int(10) UNSIGNED NOT NULL COMMENT 'appid',
  `category_style` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '分类页样式(10一级分类[大图] 11一级分类[小图] 20二级分类)',
  `share_title` varchar(100) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '分享标题',
  `wind_style` tinyint(3) UNSIGNED NOT NULL DEFAULT 1 COMMENT '分类页样式(1风格12风格23风格3)',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`app_id`) USING BTREE
) ENGINE = InnoDB CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = 'app分类页模板' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_page_category
-- ----------------------------
INSERT INTO `zmodu_page_category` VALUES (10001, 20, '11111', 2, 1593566580, 1720666320);

-- ----------------------------
-- Table structure for zmodu_plus_category
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_plus_category`;
CREATE TABLE `zmodu_plus_category`  (
  `plus_category_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '插件分类id',
  `name` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '插件分类名称',
  `image_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '分类图片id',
  `sort` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '排序方式(数字越小越靠前)',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '应用id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`plus_category_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 4 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '插件分类表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_plus_category
-- ----------------------------
INSERT INTO `zmodu_plus_category` VALUES (1, '营销插件', 0, 1, 10001, 1572087164, 1572087164);
INSERT INTO `zmodu_plus_category` VALUES (2, '吸粉插件', 0, 2, 10001, 1572087164, 1572087164);
INSERT INTO `zmodu_plus_category` VALUES (3, '促销插件', 0, 2, 10001, 1572087164, 1572087164);

-- ----------------------------
-- Table structure for zmodu_plus_wx_collection
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_plus_wx_collection`;
CREATE TABLE `zmodu_plus_wx_collection`  (
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '程序id',
  `status` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '状态：0=》关，1=》开',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(11) NOT NULL DEFAULT 0
) ENGINE = InnoDB CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '商品收藏记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_plus_wx_collection
-- ----------------------------
INSERT INTO `zmodu_plus_wx_collection` VALUES (10001, 1, 1572946736, 1572946736);

-- ----------------------------
-- Table structure for zmodu_point_product
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_point_product`;
CREATE TABLE `zmodu_point_product`  (
  `point_product_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '积分商品ID',
  `product_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '商品ID',
  `limit_num` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '限购数量',
  `stock` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '商品库存总量',
  `total_sales` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '累积兑换',
  `sales_initial` int(11) NULL DEFAULT 0 COMMENT '虚拟销量数量',
  `sort` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '商品排序(数字越小越靠前)',
  `status` tinyint(4) NULL DEFAULT 0 COMMENT '状态0，待审核 10通过，20未通过',
  `remark` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '审核备注',
  `is_delete` tinyint(1) NOT NULL DEFAULT 0 COMMENT '是否显示0，显示1，不显示',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  `shop_supplier_id` int(11) NULL DEFAULT 0 COMMENT '供应商id',
  `state` tinyint(4) NOT NULL DEFAULT 10 COMMENT '商品状态10上架，20下架',
  PRIMARY KEY (`point_product_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '积分兑换-商品表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_point_product
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_point_product_sku
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_point_product_sku`;
CREATE TABLE `zmodu_point_product_sku`  (
  `point_product_sku_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '商品sku ID',
  `point_product_id` int(11) NULL DEFAULT 0 COMMENT '积分商品id',
  `product_id` int(11) NULL DEFAULT 0 COMMENT '商品id',
  `product_sku_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '商品ID',
  `point_stock` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '商品库存总量',
  `total_sales` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '累积兑换',
  `point_num` int(11) NOT NULL DEFAULT 0 COMMENT '兑换积分数',
  `point_money` decimal(10, 2) NULL DEFAULT 0.00 COMMENT '兑换金额',
  `product_attr` varchar(500) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '商品规格信息',
  `product_price` decimal(10, 2) NULL DEFAULT 0.00 COMMENT '产品售价',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`point_product_sku_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '积分兑换-商品sku表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_point_product_sku
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_printer
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_printer`;
CREATE TABLE `zmodu_printer`  (
  `printer_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '打印机id',
  `printer_name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '打印机名称',
  `printer_type` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '打印机类型',
  `printer_config` text CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL COMMENT '打印机配置',
  `print_times` smallint(5) UNSIGNED NOT NULL DEFAULT 0 COMMENT '打印联数(次数)',
  `sort` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '排序 (数字越小越靠前)',
  `is_delete` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否删除0=显示1=隐藏',
  `shop_supplier_id` int(11) NOT NULL COMMENT '商户id',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`printer_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '小票打印机记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_printer
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_product
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_product`;
CREATE TABLE `zmodu_product`  (
  `product_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '产品id',
  `product_name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '产品名称',
  `product_price` decimal(10, 2) NULL DEFAULT 0.00 COMMENT '产品一口价',
  `line_price` decimal(10, 2) NULL DEFAULT 0.00 COMMENT '产品划线价',
  `product_no` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '产品编码',
  `product_stock` int(11) NULL DEFAULT 0 COMMENT '产品总库存',
  `video_id` int(11) NULL DEFAULT 0 COMMENT '视频id',
  `poster_id` int(11) NULL DEFAULT 0 COMMENT '视频封面id',
  `selling_point` varchar(500) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '商品卖点',
  `category_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '产品分类id',
  `spec_type` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '产品规格(10单规格 20多规格)',
  `deduct_stock_type` tinyint(3) UNSIGNED NOT NULL DEFAULT 20 COMMENT '库存计算方式(10下单减库存 20付款减库存)',
  `content` longtext CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL COMMENT '产品详情',
  `sales_initial` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '初始销量',
  `sales_actual` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '实际销量',
  `product_sort` int(10) UNSIGNED NOT NULL DEFAULT 100 COMMENT '产品排序(数字越小越靠前)',
  `delivery_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '配送模板id',
  `is_points_gift` tinyint(3) UNSIGNED NOT NULL DEFAULT 1 COMMENT '是否开启积分赠送(1开启 0关闭)',
  `is_points_discount` tinyint(3) UNSIGNED NOT NULL DEFAULT 1 COMMENT '是否允许使用积分抵扣(1允许 0不允许)',
  `max_points_discount` int(11) NULL DEFAULT 0 COMMENT '最大积分抵扣数量',
  `is_enable_grade` tinyint(3) UNSIGNED NOT NULL DEFAULT 1 COMMENT '是否开启会员折扣(1开启 0关闭)',
  `is_alone_grade` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '会员折扣设置(0默认等级折扣 1单独设置折扣)',
  `alone_grade_equity` text CHARACTER SET utf8 COLLATE utf8_general_ci NULL COMMENT '单独设置折扣的配置',
  `alone_grade_type` tinyint(4) NULL DEFAULT 10 COMMENT '折扣金额类型(10百分比 20固定金额)',
  `is_agent` tinyint(4) NULL DEFAULT 0 COMMENT '是否参加分销0否1是',
  `is_ind_agent` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否开启单独分销(0关闭 1开启)',
  `agent_money_type` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '分销佣金类型(10百分比 20固定金额)',
  `first_money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '分销佣金(一级)',
  `second_money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '分销佣金(二级)',
  `third_money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '分销佣金(三级)',
  `product_status` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '产品状态(10销售中 20仓库中 30回收站)',
  `audit_status` tinyint(4) NULL DEFAULT 0 COMMENT '审核状态0待审核10审核通过20审核未通过30强制下架40草稿',
  `audit_remark` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '审核备注',
  `view_times` int(11) NULL DEFAULT 0 COMMENT '访问次数',
  `shop_supplier_id` int(11) NULL DEFAULT 0 COMMENT '供应商id',
  `supplier_price` decimal(10, 2) NULL DEFAULT 0.00 COMMENT '供应商价格',
  `is_virtual` tinyint(4) NULL DEFAULT 0 COMMENT '是否虚拟，0否1是',
  `limit_num` int(11) NULL DEFAULT 0 COMMENT '限购数量0为不限',
  `grade_ids` varchar(200) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '可购买会员等级id，逗号隔开',
  `virtual_auto` tinyint(4) NOT NULL DEFAULT 0 COMMENT '是否自动发货1自动0手动',
  `virtual_content` varchar(200) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '虚拟物品内容',
  `is_picture` tinyint(4) NULL DEFAULT 0 COMMENT '详情是否纯图0否1是',
  `is_preview` tinyint(1) NOT NULL DEFAULT 0 COMMENT '预告商品1是0否',
  `preview_time` int(11) NOT NULL DEFAULT 0 COMMENT '预告时间',
  `add_source` tinyint(4) NOT NULL DEFAULT 10 COMMENT '商品添加来源10后台20前端',
  `content_video_id` int(11) NULL DEFAULT 0 COMMENT '详情视频id',
  `content_poster_id` int(11) NULL DEFAULT 0 COMMENT '详情视频封面id',
  `custom_form` longtext CHARACTER SET utf8 COLLATE utf8_general_ci NULL COMMENT '自定义表单信息',
  `logistics` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '10,20' COMMENT '配送方式',
  `video_type` tinyint(3) NOT NULL DEFAULT 0 COMMENT '商品视频类型0上传1链接',
  `video_link` text CHARACTER SET utf8 COLLATE utf8_general_ci NULL COMMENT '商品视频链接',
  `video_type_detail` tinyint(3) NOT NULL DEFAULT 0 COMMENT '详情视频类型0上传1链接',
  `video_link_detail` text CHARACTER SET utf8 COLLATE utf8_general_ci NULL COMMENT '详情视频链接',
  `single_num` int(11) NOT NULL DEFAULT 0 COMMENT '起购数量',
  `product_type` tinyint(3) NOT NULL DEFAULT 1 COMMENT '商品类型1普通商品2虚拟商品3卡密商品',
  `verify_num` int(11) NOT NULL DEFAULT 0 COMMENT '核销次数',
  `valid_type` tinyint(3) NOT NULL DEFAULT 10 COMMENT '核销有效期10永久20购买后几天内有效30固定日期',
  `valid_day` int(11) NOT NULL DEFAULT 0 COMMENT '购买后天数',
  `valid_start_time` int(11) NOT NULL DEFAULT 0 COMMENT '固定开始时间',
  `valid_end_time` int(11) NOT NULL DEFAULT 0 COMMENT '固定结束时间',
  `refund_status` tinyint(3) NOT NULL DEFAULT 0 COMMENT '是否支持退款0否1是',
  `overdue_refund_status` tinyint(3) NOT NULL DEFAULT 0 COMMENT '过期支持退款0否1是',
  `is_delete` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否删除',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '应用id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`product_id`) USING BTREE,
  INDEX `category_id`(`category_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 2 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '商品记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_product
-- ----------------------------
INSERT INTO `zmodu_product` VALUES (1, '全自动洗衣机', 2399.00, 3399.00, '', 1000, 0, 0, '', 57, 10, 20, '', 0, 0, 100, 0, 1, 1, 0, 1, 0, '[]', 10, 0, 0, 10, 0.00, 0.00, 0.00, 10, 10, '', 2, 1, 0.00, 0, 0, '', 0, '', 0, 0, 0, 10, 0, 0, '', '10,20', 0, NULL, 0, NULL, 0, 1, 0, 10, 0, 0, 0, 0, 0, 0, 10001, 1720666071, 1720666092);

-- ----------------------------
-- Table structure for zmodu_product_image
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_product_image`;
CREATE TABLE `zmodu_product_image`  (
  `id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `product_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '商品id',
  `image_id` int(11) NOT NULL COMMENT '图片id(关联文件记录表)',
  `image_type` tinyint(4) NULL DEFAULT 0 COMMENT '图片类型0商品主图，1详情图',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '应用id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  PRIMARY KEY (`id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 3 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '商品图片记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_product_image
-- ----------------------------
INSERT INTO `zmodu_product_image` VALUES (2, 1, 5, 0, 10001, 1720666092);

-- ----------------------------
-- Table structure for zmodu_product_reduce
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_product_reduce`;
CREATE TABLE `zmodu_product_reduce`  (
  `product_id` int(10) UNSIGNED NOT NULL COMMENT '产品id',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '应用id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`product_id`) USING BTREE
) ENGINE = InnoDB CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '商品满减表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_product_reduce
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_product_sku
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_product_sku`;
CREATE TABLE `zmodu_product_sku`  (
  `product_sku_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '产品规格id',
  `product_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '产品id',
  `spec_sku_id` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '0' COMMENT '产品sku记录索引 (由规格id组成)',
  `image_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '规格图片id',
  `product_no` varchar(100) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '产品编码',
  `product_price` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '产品价格',
  `line_price` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '产品划线价',
  `low_price` decimal(10, 2) NULL DEFAULT 0.00 COMMENT '产品底价',
  `stock_num` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '当前库存数量',
  `product_sales` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '产品销量(废弃)',
  `product_weight` double UNSIGNED NOT NULL DEFAULT 0 COMMENT '产品重量(Kg)',
  `supplier_price` decimal(10, 2) NULL DEFAULT 0.00 COMMENT '供应商价格',
  `card_type` tinyint(3) NOT NULL DEFAULT 10 COMMENT '卡密类型10固定卡密20一次性卡密',
  `card_info` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '卡密信息',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '应用id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`product_sku_id`) USING BTREE,
  UNIQUE INDEX `sku_idx`(`product_id`, `spec_sku_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 2 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '商品规格表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_product_sku
-- ----------------------------
INSERT INTO `zmodu_product_sku` VALUES (1, 1, '0', 0, '1001', 2399.00, 3399.00, 0.00, 1000, 0, 1, 0.00, 10, '', 10001, 1720666092, 1720666092);

-- ----------------------------
-- Table structure for zmodu_product_spec_rel
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_product_spec_rel`;
CREATE TABLE `zmodu_product_spec_rel`  (
  `id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `product_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '产品id',
  `spec_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '规格组id',
  `spec_value_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '规格值id',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '应用id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  PRIMARY KEY (`id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '商品与规格值关系记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_product_spec_rel
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_product_virtual
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_product_virtual`;
CREATE TABLE `zmodu_product_virtual`  (
  `virtual_id` int(11) NOT NULL AUTO_INCREMENT COMMENT 'ID',
  `product_id` int(11) NOT NULL DEFAULT 0 COMMENT '商品id',
  `product_sku_id` int(11) NOT NULL DEFAULT 0 COMMENT '商品规格id',
  `spec_sku_id` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '0' COMMENT '产品sku记录索引 (由规格id组成)',
  `card_no` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '卡号',
  `card_pwd` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '卡密',
  `order_id` int(11) NOT NULL DEFAULT 0 COMMENT '订单id',
  `user_id` int(11) NOT NULL DEFAULT 0 COMMENT '会员id',
  `use_status` tinyint(3) NOT NULL DEFAULT 10 COMMENT '使用状态10未使用20已使用',
  `use_time` int(11) NOT NULL DEFAULT 0 COMMENT '使用时间',
  `app_id` int(11) UNSIGNED NOT NULL DEFAULT 0 COMMENT '应用id',
  `create_time` int(11) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(11) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`virtual_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8mb4 COLLATE = utf8mb4_general_ci COMMENT = '商品卡密表' ROW_FORMAT = Compact;

-- ----------------------------
-- Records of zmodu_product_virtual
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_region
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_region`;
CREATE TABLE `zmodu_region`  (
  `id` int(11) NOT NULL AUTO_INCREMENT COMMENT 'ID',
  `pid` int(11) NULL DEFAULT NULL COMMENT '父id',
  `shortname` varchar(100) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT NULL COMMENT '简称',
  `name` varchar(100) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT NULL COMMENT '名称',
  `merger_name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT NULL COMMENT '全称',
  `level` tinyint(4) UNSIGNED NULL DEFAULT 0 COMMENT '层级 1 2 3 省市区县',
  `pinyin` varchar(100) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT NULL COMMENT '拼音',
  `code` varchar(100) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT NULL COMMENT '长途区号',
  `zip_code` varchar(100) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT NULL COMMENT '邮编',
  `first` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT NULL COMMENT '首字母',
  `lng` varchar(100) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT NULL COMMENT '经度',
  `lat` varchar(100) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT NULL COMMENT '纬度',
  `sort` int(11) NULL DEFAULT 100 COMMENT '排序',
  `is_delete` tinyint(3) NULL DEFAULT 0 COMMENT '是否删除0否1是',
  `create_time` int(11) NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(11) NULL DEFAULT 0 COMMENT '修改时间',
  PRIMARY KEY (`id`) USING BTREE,
  INDEX `name,level`(`name`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 4209 CHARACTER SET = utf8 COLLATE = utf8_general_ci ROW_FORMAT = Compact;

-- ----------------------------
-- Table structure for zmodu_register_record
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_register_record`;
CREATE TABLE `zmodu_register_record`  (
  `record_id` int(11) NOT NULL AUTO_INCREMENT COMMENT 'ID',
  `user_id` int(11) NOT NULL DEFAULT 0 COMMENT '会员id',
  `content` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NULL COMMENT '领取内容',
  `is_push` tinyint(3) NOT NULL DEFAULT 0 COMMENT '是否已推送0否1是',
  `app_id` int(11) UNSIGNED NOT NULL DEFAULT 0 COMMENT '程序id',
  `create_time` int(11) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(11) NOT NULL COMMENT '更新时间',
  PRIMARY KEY (`record_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8mb4 COLLATE = utf8mb4_general_ci COMMENT = '注册有礼领取记录' ROW_FORMAT = Compact;

-- ----------------------------
-- Records of zmodu_register_record
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_return_address
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_return_address`;
CREATE TABLE `zmodu_return_address`  (
  `address_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '退货地址id',
  `name` varchar(30) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '收货人姓名',
  `phone` varchar(20) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '联系电话',
  `detail` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '详细地址',
  `sort` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '排序 (数字越小越靠前)',
  `is_delete` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否删除0=显示1=隐藏',
  `shop_supplier_id` int(11) NOT NULL COMMENT '商城id',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`address_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '退货地址记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_return_address
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_seckill_activity
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_seckill_activity`;
CREATE TABLE `zmodu_seckill_activity`  (
  `seckill_activity_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `title` varchar(128) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '活动标题',
  `start_time` int(11) NOT NULL DEFAULT 0 COMMENT '活动开始时间',
  `end_time` int(11) NOT NULL DEFAULT 0 COMMENT '活动结束时间',
  `join_end_time` int(11) NULL DEFAULT 0 COMMENT '报名截止日期',
  `status` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '活动状态(1生效 0未生效)',
  `time_id` varchar(100) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '活动时间id',
  `total_num` int(10) NOT NULL DEFAULT 0 COMMENT '限购总数量',
  `single_num` int(10) NOT NULL DEFAULT 0 COMMENT '单次购买限购数量',
  `sort` tinyint(4) NULL DEFAULT 100 COMMENT '排序',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '微信app_id',
  `is_delete` tinyint(4) NULL DEFAULT 0 COMMENT '是否删除0,否1是',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`seckill_activity_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '限时秒杀活动表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_seckill_activity
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_seckill_product
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_seckill_product`;
CREATE TABLE `zmodu_seckill_product`  (
  `seckill_product_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '秒杀商品主键id',
  `product_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '商品id',
  `limit_num` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '限购数量',
  `stock` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '商品库存总量',
  `seckill_activity_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '秒杀活动id',
  `total_sales` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '累计销量',
  `sales_initial` int(11) NULL DEFAULT 0 COMMENT '虚拟销量',
  `join_num` int(11) NULL DEFAULT 0 COMMENT '参与人数',
  `status` tinyint(4) NULL DEFAULT 0 COMMENT '状态0，待审核 10通过，20未通过',
  `sort` int(11) NULL DEFAULT 100 COMMENT '排序',
  `shop_supplier_id` int(11) NULL DEFAULT 0 COMMENT '供应商id',
  `remark` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '审核备注',
  `state` tinyint(4) NOT NULL DEFAULT 10 COMMENT '商品状态10上架，20下架',
  `is_delete` int(11) NULL DEFAULT 0 COMMENT '是否删除1，是，0否',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '微信app_id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`seckill_product_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '限时秒杀商品表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_seckill_product
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_seckill_product_sku
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_seckill_product_sku`;
CREATE TABLE `zmodu_seckill_product_sku`  (
  `seckill_product_sku_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '商品sku id',
  `seckill_product_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '秒杀商品id',
  `seckill_activity_id` int(11) NULL DEFAULT 0 COMMENT '秒杀活动id',
  `product_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '商品id',
  `product_sku_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '商品sku id',
  `product_attr` varchar(500) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '商品规格信息',
  `seckill_price` decimal(10, 2) UNSIGNED NOT NULL COMMENT '秒杀价',
  `seckill_stock` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '秒杀库存',
  `product_price` decimal(10, 2) NULL DEFAULT 0.00 COMMENT '产品售价',
  `sales_num` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '累计销量',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '微信app_id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`seckill_product_sku_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '限时秒杀-sku表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_seckill_product_sku
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_seckill_time
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_seckill_time`;
CREATE TABLE `zmodu_seckill_time`  (
  `id` int(11) NOT NULL AUTO_INCREMENT COMMENT 'ID',
  `title` varchar(100) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '活动名称',
  `start_time` varchar(100) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '开始时间',
  `end_time` varchar(100) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '结束时间',
  `status` tinyint(3) NOT NULL DEFAULT 1 COMMENT '状态1开启0隐藏',
  `app_id` int(11) UNSIGNED NOT NULL DEFAULT 0 COMMENT '程序id',
  `create_time` int(11) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(11) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8mb4 COLLATE = utf8mb4_general_ci COMMENT = '秒杀时间配置' ROW_FORMAT = Compact;

-- ----------------------------
-- Records of zmodu_seckill_time
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_setting
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_setting`;
CREATE TABLE `zmodu_setting`  (
  `key` varchar(30) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL COMMENT '设置项标示',
  `describe` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '设置项描述',
  `values` longtext CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL COMMENT '设置内容（json格式）',
  `shop_supplier_id` int(11) NOT NULL DEFAULT 0 COMMENT '商户id',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  UNIQUE INDEX `unique_key`(`app_id`, `key`, `shop_supplier_id`) USING BTREE
) ENGINE = InnoDB CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '商城设置记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_setting
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_shop_access
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_shop_access`;
CREATE TABLE `zmodu_shop_access`  (
  `access_id` int(10) UNSIGNED NOT NULL COMMENT '主键id',
  `name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '权限名称',
  `path` varchar(128) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '路由地址',
  `parent_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '父级id',
  `sort` tinyint(3) UNSIGNED NOT NULL DEFAULT 100 COMMENT '排序(数字越小越靠前)',
  `icon` varchar(128) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '菜单图标',
  `redirect_name` varchar(128) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '重定向名称',
  `is_route` tinyint(1) NOT NULL DEFAULT 0 COMMENT '是否是路由 0=不是1=是',
  `is_menu` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否是菜单 0不是 1是',
  `alias` varchar(128) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '别名(废弃)',
  `is_show` tinyint(3) UNSIGNED NOT NULL DEFAULT 1 COMMENT '是否显示1=显示0=不显示',
  `plus_category_id` int(11) NULL DEFAULT 0 COMMENT '插件分类id',
  `remark` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '描述',
  `upload_icon` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NULL DEFAULT '' COMMENT '上传菜单图标',
  `app_id` int(10) UNSIGNED NULL DEFAULT 10001 COMMENT 'app_id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`access_id`) USING BTREE,
  UNIQUE INDEX `idx_path`(`path`) USING BTREE
) ENGINE = InnoDB CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '商家用户权限表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_shop_access
-- ----------------------------
INSERT INTO `zmodu_shop_access` VALUES (14, '商品', '/product', 0, 0, 'icon-shangping', '/product/product/index', 1, 1, 'product', 1, 0, '', '', 10001, 1574333176, 1606370095);
INSERT INTO `zmodu_shop_access` VALUES (15, '商品管理', '/product/product/index', 14, 0, '', '', 1, 1, 'product_index', 1, 0, '', '', 10001, 1574333221, 1592203199);
INSERT INTO `zmodu_shop_access` VALUES (39, '订单', '/order', 0, 1, 'icon-icon-test', '/order/order/index', 1, 1, 'order', 1, 0, '', '', 10001, 1574931867, 1591181335);
INSERT INTO `zmodu_shop_access` VALUES (40, '订单管理', '/order/order/index', 39, 0, '', '', 1, 1, 'order_index', 1, 0, '', '', 10001, 1574932080, 1576288013);
INSERT INTO `zmodu_shop_access` VALUES (41, '编辑商品', '/product/product/edit', 15, 1, '', '', 1, 0, 'product_edit', 1, 0, '', '', 10001, 1574938802, 1576220678);
INSERT INTO `zmodu_shop_access` VALUES (42, '商品分类', '/product/category/index', 14, 1, '', '', 1, 1, 'category_index', 1, 0, '', '', 10001, 1574939256, 1575364640);
INSERT INTO `zmodu_shop_access` VALUES (45, '售后管理', '/order/refund/index', 39, 1, '', '', 1, 1, 'refund_refund', 1, 0, '', '', 10001, 1575342052, 1591955681);
INSERT INTO `zmodu_shop_access` VALUES (47, '售后详情', '/order/refund/detail', 45, 2, '', '', 1, 0, 'refund_detail', 1, 0, '', '', 10001, 1575352981, 1576221706);
INSERT INTO `zmodu_shop_access` VALUES (49, '订单详情', '/order/order/detail', 40, 1, '', '', 1, 0, 'order_detail', 1, 0, '', '', 10001, 1575353695, 1576221490);
INSERT INTO `zmodu_shop_access` VALUES (52, '设置', '/setting', 0, 10, 'icon-icon-test1', '/setting/store/index', 1, 1, 'setting', 1, 0, '', '', 10001, 1575359731, 1591956122);
INSERT INTO `zmodu_shop_access` VALUES (53, '商城设置', '/setting/store/index', 52, 1, '', '', 1, 1, 'setting_store', 1, 0, '', '', 10001, 1575359827, 1591956035);
INSERT INTO `zmodu_shop_access` VALUES (54, '会员', '/user', 0, 2, 'icon-huiyuan', '/user/user/index', 1, 1, 'member', 1, 0, '', '', 10001, 1575424557, 1592019412);
INSERT INTO `zmodu_shop_access` VALUES (55, '会员管理', '/user/user/index', 54, 1, '', '', 1, 1, 'menber_index', 1, 0, '', '', 10001, 1575425107, 1592019070);
INSERT INTO `zmodu_shop_access` VALUES (56, '等级管理', '/user/grade/index', 54, 2, '', '', 1, 1, 'member_grade', 1, 0, '', '', 10001, 1575425249, 1592019516);
INSERT INTO `zmodu_shop_access` VALUES (58, '财务概况', '/finance/financeSituation', 57, 1, '', '', 1, 0, 'finance_financesituation', 1, 0, '', '', 10001, 1575425405, 1577087762);
INSERT INTO `zmodu_shop_access` VALUES (61, '统计', '/statistics', 0, 4, 'icon-tongji', '/statistics/sales/index', 1, 1, 'statistics', 1, 0, '', '', 10001, 1575425980, 1595317784);
INSERT INTO `zmodu_shop_access` VALUES (62, '销售统计', '/statistics/sales/index', 61, 1, '', '', 1, 1, 'statistics_Data', 1, 0, '', '', 10001, 1575426033, 1595317691);
INSERT INTO `zmodu_shop_access` VALUES (63, '门店', '/store/index', 263, 5, '', '', 1, 1, 'store', 1, 0, '', '', 10001, 1575426188, 1604557134);
INSERT INTO `zmodu_shop_access` VALUES (64, '门店列表', '/store/store/index', 63, 1, '', '', 1, 1, 'store_index', 1, 0, '', '', 10001, 1575426245, 1604542635);
INSERT INTO `zmodu_shop_access` VALUES (65, '店员列表', '/store/clerk/index', 63, 3, '', '', 1, 1, 'store_clerk_index', 1, 0, '', '', 10001, 1575426295, 1576288613);
INSERT INTO `zmodu_shop_access` VALUES (66, '订单核销记录', '/store/order/index', 63, 2, '', '', 1, 1, 'store_order_index', 1, 0, '', '', 10001, 1575426484, 1592208037);
INSERT INTO `zmodu_shop_access` VALUES (67, '编辑门店', '/store/store/edit', 64, 2, '', '', 1, 0, 'store_edit', 1, 0, '', '', 10001, 1575426657, 1576222576);
INSERT INTO `zmodu_shop_access` VALUES (68, '添加门店', '/store/store/add', 64, 1, '', '', 1, 0, 'store_add', 1, 0, '', '', 10001, 1575426746, 1576222543);
INSERT INTO `zmodu_shop_access` VALUES (69, '添加店员', '/store/clerk/add', 65, 1, '', '', 1, 0, 'clerk_add', 1, 0, '', '', 10001, 1575426942, 1576222719);
INSERT INTO `zmodu_shop_access` VALUES (70, '编辑店员', '/store/clerk/edit', 65, 2, '', '', 1, 0, 'clerk_edit', 1, 0, '', '', 10001, 1575427016, 1576222751);
INSERT INTO `zmodu_shop_access` VALUES (71, '页面', '/page', 0, 7, 'icon-iconset0335', '/page/page/list', 1, 1, 'page', 1, 0, '', '', 10001, 1575427143, 1592029821);
INSERT INTO `zmodu_shop_access` VALUES (73, '插件', '/plus', 0, 8, 'icon-chajian1', '/plus/plus/index', 1, 1, 'plus', 1, 0, '', '', 10001, 1575427389, 1606377006);
INSERT INTO `zmodu_shop_access` VALUES (74, '插件中心', '/plus/plus/index', 73, 1, '', '', 1, 1, 'plus_index', 1, 0, '', '', 10001, 1575427446, 1592031902);
INSERT INTO `zmodu_shop_access` VALUES (75, '交易设置', '/setting/trade/index', 52, 2, '', '', 1, 1, 'setting_trade', 1, 0, '', '', 10001, 1575427639, 1591956370);
INSERT INTO `zmodu_shop_access` VALUES (77, '物流公司', '/setting/express/index', 52, 4, '', '', 1, 1, 'setting_express_index', 1, 0, '', '', 10001, 1575427795, 1576288405);
INSERT INTO `zmodu_shop_access` VALUES (78, '消息设置', '/setting/message/index', 52, 5, '', '', 1, 1, 'setting_message', 1, 0, '', '', 10001, 1575427840, 1576288415);
INSERT INTO `zmodu_shop_access` VALUES (81, '上传设置', '/setting/storage/index', 52, 8, '', '', 1, 1, 'setting_storage', 1, 0, '', '', 10001, 1575427949, 1591956959);
INSERT INTO `zmodu_shop_access` VALUES (84, '清理缓存', '/setting/clear/index', 52, 11, '', '', 1, 1, 'setting_clear', 1, 0, '', '', 10001, 1575428087, 1591957018);
INSERT INTO `zmodu_shop_access` VALUES (85, '应用', '/appsetting', 0, 9, 'icon-application', '/appsetting/app/index', 1, 1, 'appsettings', 1, 0, '', '', 10001, 1575428240, 1592028610);
INSERT INTO `zmodu_shop_access` VALUES (86, '基础设置', '/appsetting/app/index', 85, 1, '', '', 1, 1, 'appsettings_appbase', 1, 0, '', '', 10001, 1575428301, 1592028117);
INSERT INTO `zmodu_shop_access` VALUES (87, '小程序', '/appsetting/appwx/index', 85, 2, '', '', 1, 1, 'appsettings_appwx', 1, 0, '', '', 10001, 1575428355, 1592028147);
INSERT INTO `zmodu_shop_access` VALUES (88, '公众号/h5', '/appsetting/appmp/index', 85, 3, '', '', 1, 1, 'appsettings_appmp', 1, 0, '', '', 10001, 1575428396, 1592028167);
INSERT INTO `zmodu_shop_access` VALUES (89, '权限', '/auth', 0, 11, 'icon-authority', '/auth/user/index', 1, 1, 'auth', 1, 0, '', '', 10001, 1575428502, 1576288793);
INSERT INTO `zmodu_shop_access` VALUES (90, '管理员列表', '/auth/user/index', 89, 1, '', '', 1, 1, 'auth_user_index', 1, 0, '', '', 10001, 1575428548, 1576288472);
INSERT INTO `zmodu_shop_access` VALUES (91, '角色管理', '/auth/role/index', 89, 2, '', '', 1, 1, 'auth_role_index', 1, 0, '', '', 10001, 1575428592, 1576288479);
INSERT INTO `zmodu_shop_access` VALUES (92, '添加管理员', '/auth/user/add', 90, 1, '', '', 1, 0, 'user_add', 1, 0, '', '', 10001, 1575428670, 1576223932);
INSERT INTO `zmodu_shop_access` VALUES (93, '编辑管理员', '/auth/user/edit', 90, 2, '', '', 1, 0, 'user_edit', 1, 0, '', '', 10001, 1575428718, 1576223949);
INSERT INTO `zmodu_shop_access` VALUES (94, '添加角色', '/auth/role/add', 91, 1, '', '', 1, 0, 'role_add', 1, 0, '', '', 10001, 1575428782, 1576224031);
INSERT INTO `zmodu_shop_access` VALUES (95, '编辑角色', '/auth/role/edit', 91, 2, '', '', 1, 0, 'role_edit', 1, 0, '', '', 10001, 1575428833, 1576224010);
INSERT INTO `zmodu_shop_access` VALUES (96, '积分管理', '/user/points/index', 54, 4, '', '', 1, 1, 'member_points_index', 1, 0, '', '', 10001, 1575429689, 1592020209);
INSERT INTO `zmodu_shop_access` VALUES (97, '优惠券', '/plus/coupon/index', 74, 2, 'icon-weibiaoti2fuzhi02', '', 1, 1, 'plus_coupon_index', 1, 2, '将优惠进行到底', '', 10001, 1575429858, 1607567838);
INSERT INTO `zmodu_shop_access` VALUES (98, '添加优惠券', '/plus/coupon/coupon/add', 241, 1, '', '', 1, 0, 'plus_coupon_list_add', 1, 0, '', '', 10001, 1575429999, 1594979742);
INSERT INTO `zmodu_shop_access` VALUES (99, '分销', '/plus/agent/index', 74, 3, 'icon-fenxiao', '', 1, 1, 'plus_agent_Index', 1, 1, '客户带客户，销量涨涨涨', '', 10001, 1575430531, 1607567849);
INSERT INTO `zmodu_shop_access` VALUES (100, '文章', '/plus/article', 74, 4, 'icon-16', '/plus/article/index', 1, 1, 'plus_article_Index', 1, 1, '动心的文案促销的利器', '', 10001, 1575430639, 1607567870);
INSERT INTO `zmodu_shop_access` VALUES (101, '引导收藏', '/plus/collection/index', 74, 5, 'icon-collection', '', 1, 1, 'plus_collection_index', 1, 1, '快速访问小程序', '', 10001, 1575430698, 1607567885);
INSERT INTO `zmodu_shop_access` VALUES (103, '限时秒杀', '/plus/seckill/index', 74, 7, 'icon-miaosha', '', 1, 1, 'plus_seckill_goods', 1, 2, '限时抢购，引导客户快速消费', '', 10001, 1575430992, 1607567923);
INSERT INTO `zmodu_shop_access` VALUES (104, '限时砍价', '/plus/bargain/index', 74, 8, 'icon-kanjia', '', 1, 0, 'plus_bargain_index', 1, 2, '邀请好友助力，轻松裂变上百新会员', '', 10001, 1575431088, 1607567941);
INSERT INTO `zmodu_shop_access` VALUES (112, '编辑优惠券', '/plus/coupon/coupon/edit', 241, 2, '', '', 1, 0, 'plus_coupon_list_edit', 1, 0, '', '', 10001, 1575454566, 1594979744);
INSERT INTO `zmodu_shop_access` VALUES (113, '添加文章', '/plus/article/article/add', 224, 2, '', '', 1, 1, 'plus_article_Add', 1, 0, '', '', 10001, 1575454725, 1592214338);
INSERT INTO `zmodu_shop_access` VALUES (114, '编辑文章', '/plus/article/article/edit', 224, 3, '', '', 1, 1, 'plus_article_Edit', 1, 0, '', '', 10001, 1575454781, 1592214348);
INSERT INTO `zmodu_shop_access` VALUES (116, '添加活动', '/plus/seckill/active/add', 245, 2, '', '', 1, 1, 'plus_seckill_active_add', 1, 0, '', '', 10001, 1575454959, 1576288346);
INSERT INTO `zmodu_shop_access` VALUES (117, '编辑活动', '/plus/seckill/active/edit', 245, 4, '', '', 1, 1, 'plus_seckill_active_Edit', 1, 0, '', '', 10001, 1575455012, 1578895959);
INSERT INTO `zmodu_shop_access` VALUES (118, '页面列表', '/page/page/index', 71, 2, '', '', 1, 1, 'page_lists', 1, 0, '', '', 10001, 1575697716, 1592029804);
INSERT INTO `zmodu_shop_access` VALUES (120, '余额管理', '/user/balance/index', 54, 4, '', '', 1, 1, 'member_log', 1, 0, '', '', 10001, 1575712385, 1596072865);
INSERT INTO `zmodu_shop_access` VALUES (122, '商品评价', '/product/comment/index', 14, 3, '', '', 1, 1, 'product_comment_evaluation', 1, 0, '', '', 10001, 1575852391, 1591955294);
INSERT INTO `zmodu_shop_access` VALUES (123, '评价详情', '/product/comment/detail', 122, 1, '', '', 1, 0, 'comment_detail', 1, 0, '', '', 10001, 1575852589, 1576221135);
INSERT INTO `zmodu_shop_access` VALUES (124, '添加运费', '/setting/delivery/add', 76, 1, '', '', 1, 0, 'delivery_add', 1, 0, '', '', 10001, 1575941834, 1576223623);
INSERT INTO `zmodu_shop_access` VALUES (125, '编辑运费', '/setting/delivery/edit', 76, 2, '', '', 1, 0, 'delivery_edit', 1, 0, '', '', 10001, 1575941891, 1576223609);
INSERT INTO `zmodu_shop_access` VALUES (126, '添加物流', '/setting/express/add', 77, 1, '', '', 1, 0, 'express_add', 1, 0, '', '', 10001, 1575941958, 1576223586);
INSERT INTO `zmodu_shop_access` VALUES (127, '编辑物流', '/setting/express/edit', 77, 2, '', '', 1, 0, 'express_edit', 1, 0, '', '', 10001, 1575941997, 1576223573);
INSERT INTO `zmodu_shop_access` VALUES (128, '添加地址', '/setting/address/add', 80, 1, '', '', 1, 0, 'address_add', 1, 0, '', '', 10001, 1575942071, 1576223529);
INSERT INTO `zmodu_shop_access` VALUES (129, '编辑地址', '/setting/address/edit', 80, 2, '', '', 1, 0, 'address_edit', 1, 0, '', '', 10001, 1575942113, 1576223545);
INSERT INTO `zmodu_shop_access` VALUES (130, '添加打印机', '/setting/printer/add', 82, 1, '', '', 1, 0, 'printer_add', 1, 0, '', '', 10001, 1575942184, 1576223813);
INSERT INTO `zmodu_shop_access` VALUES (131, '编辑打印机', '/setting/printer/edit', 82, 2, '', '', 1, 0, 'printer_edit', 1, 0, '', '', 10001, 1575942238, 1576223798);
INSERT INTO `zmodu_shop_access` VALUES (132, '限时拼团', '/plus/assemble/index', 74, 7, 'icon-gengduopintuan', '', 1, 0, 'plus_assemble_goods', 1, 2, '客户自发邀请好友一起购买', '', 10001, 1575942847, 1607567933);
INSERT INTO `zmodu_shop_access` VALUES (133, '删除评价', '/product/comment/delete', 122, 2, '', '', 1, 0, 'comment|_delete', 1, 0, '', '', 10001, 1575943511, 1576221202);
INSERT INTO `zmodu_shop_access` VALUES (136, '基础设置', '/plus/assemble/setting/index', 132, 4, '', '', 1, 0, '_plus_assemble_product_add', 1, 0, '', '', 10001, 1576028948, 1594516602);
INSERT INTO `zmodu_shop_access` VALUES (143, '删除商品', '/product/product/delete', 15, 3, '', '', 1, 0, 'product_delete', 1, 0, '', '', NULL, 1576220720, 1576220720);
INSERT INTO `zmodu_shop_access` VALUES (145, '添加分类', '/product/category/add', 42, 1, '', '', 1, 0, 'category_add', 1, 0, '', '', NULL, 1576220915, 1576220915);
INSERT INTO `zmodu_shop_access` VALUES (146, '编辑分类', '/product/category/edit', 42, 2, '', '', 1, 0, 'category_edit', 1, 0, '', '', NULL, 1576220968, 1576220968);
INSERT INTO `zmodu_shop_access` VALUES (147, '删除分类', '/product/category/delete', 42, 3, '', '', 1, 0, 'category_delete', 1, 0, '', '', NULL, 1576221000, 1576221000);
INSERT INTO `zmodu_shop_access` VALUES (148, '会员充值', '/user/user/recharge', 55, 1, '', '', 1, 0, '/member/member/recharge', 1, 0, '', '', NULL, 1576222057, 1592020320);
INSERT INTO `zmodu_shop_access` VALUES (149, '会员编辑', '/user/user/edit', 55, 2, '', '', 1, 0, '/member/member/grade', 1, 0, '', '', NULL, 1576222118, 1592020342);
INSERT INTO `zmodu_shop_access` VALUES (150, '删除会员', '/user/user/delete', 55, 3, '', '', 1, 0, '/member/member/delete', 1, 0, '', '', NULL, 1576222165, 1592020351);
INSERT INTO `zmodu_shop_access` VALUES (151, '添加等级', '/user/grade/add', 56, 1, '', '', 1, 0, '/member/grade/add', 1, 0, '', '', NULL, 1576222269, 1592019499);
INSERT INTO `zmodu_shop_access` VALUES (152, '编辑等级', '/user/grade/edit', 56, 2, '', '', 1, 0, '/member/grade/edit', 1, 0, '', '', NULL, 1576222339, 1592019523);
INSERT INTO `zmodu_shop_access` VALUES (153, '删除等级', '/user/grade/delete', 56, 3, '', '', 1, 0, '/member/grade/delete', 1, 0, '', '', NULL, 1576222364, 1592019530);
INSERT INTO `zmodu_shop_access` VALUES (154, '删除门店', '/store/store/delete', 64, 3, '', '', 1, 0, 'store_delete', 1, 0, '', '', NULL, 1576222609, 1576222609);
INSERT INTO `zmodu_shop_access` VALUES (155, '删除店员', '/store/clerk/delete', 65, 3, '', '', 1, 0, 'clerk_delete', 1, 0, '', '', NULL, 1576222789, 1576222789);
INSERT INTO `zmodu_shop_access` VALUES (156, '编辑页面', '/page/page/edit', 118, 2, '', '', 1, 0, 'page_edit', 1, 0, '', '', NULL, 1576222920, 1592030602);
INSERT INTO `zmodu_shop_access` VALUES (157, '添加页面', '/page/page/add', 118, 1, '', '', 1, 0, 'page_add', 1, 0, '', '', NULL, 1576222978, 1592030579);
INSERT INTO `zmodu_shop_access` VALUES (158, '删除页面', '/page/page/delete', 118, 3, '', '', 0, 0, 'page_delete', 1, 0, '', '', NULL, 1576223041, 1592030615);
INSERT INTO `zmodu_shop_access` VALUES (160, '删除运费', '/setting/delivery/delete', 76, 3, '', '', 1, 0, 'delivery_delete', 1, 0, '', '', NULL, 1576223228, 1576223228);
INSERT INTO `zmodu_shop_access` VALUES (161, '删除物流', '/setting/express/delete', 77, 3, '', '', 1, 0, 'express_delete', 1, 0, '', '', NULL, 1576223379, 1576223379);
INSERT INTO `zmodu_shop_access` VALUES (162, '删除地址', '/setting/address/delete', 80, 3, '', '', 1, 0, 'address_delete', 1, 0, '', '', NULL, 1576223509, 1576223509);
INSERT INTO `zmodu_shop_access` VALUES (163, '删除打印机', '/setting/printer/delete', 82, 3, '', '', 1, 0, 'printer_delete', 1, 0, '', '', NULL, 1576223776, 1576223776);
INSERT INTO `zmodu_shop_access` VALUES (164, '删除管理员', '/auth/user/delete', 90, 3, '', '', 1, 0, 'user_delete', 1, 0, '', '', NULL, 1576223898, 1576223898);
INSERT INTO `zmodu_shop_access` VALUES (165, '删除角色', '/auth/role/delete', 91, 3, '', '', 1, 0, 'role_delete', 1, 0, '', '', NULL, 1576223985, 1576223985);
INSERT INTO `zmodu_shop_access` VALUES (169, '物流编码', '/setting/express/company', 77, 4, '', '', 1, 0, 'setting_express_company', 1, 0, '', '', NULL, 1577268734, 1577268785);
INSERT INTO `zmodu_shop_access` VALUES (170, '公众号关注', '/plus/officia/index', 74, 8, 'icon-gongzhonghaoguanli', '', 1, 1, 'plus_officia_index', 1, 1, '公众号聚粉', '', 0, 1577696979, 1607567953);
INSERT INTO `zmodu_shop_access` VALUES (171, '积分商城', '/plus/points/index', 74, 1, 'icon-jifen', '', 1, 1, 'plus_point_index', 1, 3, '积分兑换商品', '', 0, 1577757130, 1607567437);
INSERT INTO `zmodu_shop_access` VALUES (172, '添加积分商品', '/plus/points/product/add', 215, 2, '', '', 1, 0, 'plus_point_product_add', 1, 0, '', '', 0, 1577759704, 1592271974);
INSERT INTO `zmodu_shop_access` VALUES (173, '编辑积分商品', '/plus/points/product/edit', 215, 3, '', '', 1, 0, 'plus_point_product_edit', 1, 0, '', '', 0, 1577774817, 1592211768);
INSERT INTO `zmodu_shop_access` VALUES (174, '删除积分商品', '/plus/points/product/delete', 215, 4, '', '', 1, 0, 'plus_point_product_del', 1, 0, '', '', 0, 1577778221, 1592272726);
INSERT INTO `zmodu_shop_access` VALUES (175, '商品推荐', '/plus/recommend/index', 74, 9, 'icon-tuijian1', '', 1, 1, 'plus_recommend_index', 1, 1, '推荐指定商品给用户', '', 0, 1578275635, 1607567969);
INSERT INTO `zmodu_shop_access` VALUES (176, '签到有礼', '/plus/sign', 74, 1, 'icon-qiandao', '/plus/sign/index', 1, 1, 'plus_sign_index', 1, 3, '签到享好礼，提升客户粘性', '', 0, 1578371850, 1607567769);
INSERT INTO `zmodu_shop_access` VALUES (178, '添加礼包购', '/plus/package/add', 177, 2, '', '', 1, 1, 'plus_package_add', 1, 0, '', '', NULL, 1578451902, 1578472377);
INSERT INTO `zmodu_shop_access` VALUES (179, '发布', '/plus/package/send', 177, 3, '', '', 1, 0, 'plus_package_send', 1, 0, '', '', NULL, 1578454811, 1578454811);
INSERT INTO `zmodu_shop_access` VALUES (180, '编辑', '/plus/package/edit', 177, 4, '', '', 1, 1, 'plus_package_edit', 1, 0, '', '', NULL, 1578455012, 1578472542);
INSERT INTO `zmodu_shop_access` VALUES (181, '删除', '/plus/package/delete', 177, 5, '', '', 1, 0, 'plus_package_del', 1, 0, '', '', 0, 1578455061, 1592272755);
INSERT INTO `zmodu_shop_access` VALUES (182, '推广', '/plus/package/pushs', 177, 6, '', '', 1, 1, 'plus_package_pushs', 1, 0, '', '', NULL, 1578455231, 1578455231);
INSERT INTO `zmodu_shop_access` VALUES (183, '购买记录', '/plus/package/orderlist', 177, 6, '', '', 1, 0, 'plus_package_orderlist', 1, 0, '', '', NULL, 1578471167, 1578472694);
INSERT INTO `zmodu_shop_access` VALUES (185, '首页推送', '/plus/homepush/index', 74, 1, 'icon-tuisong', '', 1, 1, 'plus_homepush_Index', 1, 1, '推送最新消息给用户', '', 0, 1578479354, 1607567788);
INSERT INTO `zmodu_shop_access` VALUES (190, '发布', '/plus/invitation/send', 186, 1, '', '', 1, 1, 'plus_invitation_send', 1, 0, '', '', NULL, 1578560682, 1578560682);
INSERT INTO `zmodu_shop_access` VALUES (191, '终止', '/plus/invitation/end', 186, 3, '', '', 1, 1, 'plus_invitation_end', 1, 0, '', '', NULL, 1578561092, 1578561199);
INSERT INTO `zmodu_shop_access` VALUES (192, '参与记录', '/plus/invitation/partake', 186, 7, '', '', 1, 1, 'plus_invitation_partake', 1, 0, '', '', NULL, 1578561789, 1578640760);
INSERT INTO `zmodu_shop_access` VALUES (193, '推广', '/plus/invitation/pushs', 186, 1, '', '', 1, 1, 'plus_invitation_pushs', 1, 0, '', '', NULL, 1578561928, 1578561928);
INSERT INTO `zmodu_shop_access` VALUES (196, '砍价列表', '/plus/bargain/task/index', 104, 3, '', '', 1, 0, 'plus_bargain_productlist', 1, 0, '', '', 0, 1578967118, 1594517093);
INSERT INTO `zmodu_shop_access` VALUES (197, '砍价设置', '/plus/bargain/setting/index', 104, 5, '', '', 1, 1, 'plus_bargain_product_add', 1, 0, '', '', 0, 1578967621, 1594517243);
INSERT INTO `zmodu_shop_access` VALUES (198, '砍价详情', '/plus/bargain/task/help', 196, 3, '', '', 1, 1, 'plus_bargain_product_edit', 1, 0, '', '', 0, 1578982795, 1594517202);
INSERT INTO `zmodu_shop_access` VALUES (211, '短信设置', '/setting/sms/index', 52, 5, '', '', 1, 1, '', 1, 0, '', '', NULL, 1592016295, 1592018633);
INSERT INTO `zmodu_shop_access` VALUES (212, '入驻申请', '/plus/agent/apply/index', 99, 1, '', '', 0, 0, '', 1, 0, '', '', NULL, 1592035401, 1592035401);
INSERT INTO `zmodu_shop_access` VALUES (213, '签到记录', '/plus/sign/lists', 176, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1592209550, 1592209550);
INSERT INTO `zmodu_shop_access` VALUES (214, '签到设置', '/plus/sign/index', 176, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1592209645, 1592209645);
INSERT INTO `zmodu_shop_access` VALUES (215, '商品设置', '/plus/points/product/index', 171, 1, '', '/plus/point/product/index', 1, 0, 'plus_point_product_add', 1, 0, '', '', 0, 1592210480, 1592272351);
INSERT INTO `zmodu_shop_access` VALUES (217, '分销商用户', '/plus/agent/user/index', 99, 1, '', '', 0, 0, '', 1, 0, '', '', NULL, 1592211104, 1592211104);
INSERT INTO `zmodu_shop_access` VALUES (218, '分销订单', '/plus/agent/order/index', 99, 1, '', '', 0, 0, '', 1, 0, '', '', NULL, 1592211128, 1592211128);
INSERT INTO `zmodu_shop_access` VALUES (219, '提现申请', '/plus/agent/cash/index', 99, 1, '', '', 0, 0, '', 1, 0, '', '', NULL, 1592211154, 1592211154);
INSERT INTO `zmodu_shop_access` VALUES (220, '分销设置', '/plus/agent/setting/index', 99, 1, '', '', 0, 0, '', 1, 0, '', '', NULL, 1592211176, 1592211176);
INSERT INTO `zmodu_shop_access` VALUES (221, '海报设置', '/plus/agent/poster/index', 99, 1, '', '', 0, 0, '', 1, 0, '', '', 0, 1592211208, 1592211221);
INSERT INTO `zmodu_shop_access` VALUES (222, '兑换设置', '/plus/points/product/settings', 171, 1, '', '', 1, 0, '', 1, 0, '', '', 0, 1592212742, 1592212880);
INSERT INTO `zmodu_shop_access` VALUES (223, '兑换记录', '/plus/points/product/record', 171, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1592213586, 1592213586);
INSERT INTO `zmodu_shop_access` VALUES (224, '文章管理', '/plus/article/index', 100, 1, '', '', 1, 0, '', 1, 0, '', '', 0, 1592214175, 1592215442);
INSERT INTO `zmodu_shop_access` VALUES (225, '文章列表', '/plus/article/article/index', 224, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1592214317, 1592214317);
INSERT INTO `zmodu_shop_access` VALUES (226, '下级用户', '/plus/agent/user/fans', 217, 1, '', '', 0, 0, '', 1, 0, '', '', NULL, 1592217059, 1592217059);
INSERT INTO `zmodu_shop_access` VALUES (227, '删除文章', '/plus/article/article/delete', 224, 3, '', '', 0, 1, 'plus_article_Edit', 1, 0, '', '', NULL, 1592217117, 1592217117);
INSERT INTO `zmodu_shop_access` VALUES (228, '修改', '/plus/agent/user/edit', 217, 1, '', '', 0, 0, '', 1, 0, '', '', NULL, 1592217274, 1592217274);
INSERT INTO `zmodu_shop_access` VALUES (229, '删除', '/plus/agent/user/delete', 217, 1, '', '', 0, 0, '', 1, 0, '', '', NULL, 1592217336, 1592217336);
INSERT INTO `zmodu_shop_access` VALUES (230, '分类管理', '/plus/article/category', 100, 1, '', '/plus/article/category/index', 1, 0, '', 1, 0, '', '', NULL, 1592217566, 1592217566);
INSERT INTO `zmodu_shop_access` VALUES (231, '分类列表', '/plus/article/category/index', 230, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1592217637, 1592217637);
INSERT INTO `zmodu_shop_access` VALUES (232, '添加分类', '/plus/article/category/add', 230, 2, '', '', 1, 0, '', 1, 0, '', '', 0, 1592217658, 1592217682);
INSERT INTO `zmodu_shop_access` VALUES (233, '编辑分类', '/plus/article/category/edit', 230, 3, '', '', 1, 0, '', 1, 0, '', '', NULL, 1592217675, 1592217675);
INSERT INTO `zmodu_shop_access` VALUES (234, '删除分类', '/plus/article/category/delete', 230, 4, '', '', 0, 0, '', 1, 0, '', '', 0, 1592217696, 1592217701);
INSERT INTO `zmodu_shop_access` VALUES (235, '审核', '/plus/agent/apply/editApplyStatus', 212, 1, '', '', 0, 0, '', 1, 0, '', '', NULL, 1592218172, 1592218172);
INSERT INTO `zmodu_shop_access` VALUES (236, '确认打款', '/plus/agent/cash/money', 219, 1, '', '', 0, 0, '', 1, 0, '', '', NULL, 1592218469, 1592218469);
INSERT INTO `zmodu_shop_access` VALUES (237, '审核', '/plus/agent/cash/submit', 219, 1, '', '', 0, 0, '', 1, 0, '', '', NULL, 1592218560, 1592218560);
INSERT INTO `zmodu_shop_access` VALUES (241, '优惠券列表', '/plus/coupon/coupon/index', 97, 1, '', '', 1, 0, '', 1, 0, '', '', 0, 1592275863, 1592277368);
INSERT INTO `zmodu_shop_access` VALUES (242, '领取记录', '/plus/coupon/coupon/receive', 97, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1592275974, 1592275974);
INSERT INTO `zmodu_shop_access` VALUES (243, '发送优惠券', '/plus/coupon/coupon/SendCoupon', 97, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1592276320, 1592276320);
INSERT INTO `zmodu_shop_access` VALUES (245, '活动列表', '/plus/seckill/active/index', 103, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1593324947, 1593324947);
INSERT INTO `zmodu_shop_access` VALUES (246, '分类模板', '/page/page/category', 71, 3, '', '', 1, 1, '', 1, 0, '', '', 0, 1593399888, 1604990890);
INSERT INTO `zmodu_shop_access` VALUES (250, '直播', '/plus/live/index', 74, 1, '', '', 1, 0, '', 1, 3, '直播带货，销量暴涨', '', 0, 1594983966, 1607568281);
INSERT INTO `zmodu_shop_access` VALUES (251, '会员统计', '/statistics/user/index', 61, 1, '', '', 1, 1, '', 1, 0, '', '', 0, 1595313049, 1595313330);
INSERT INTO `zmodu_shop_access` VALUES (252, '登录日志', '/auth/loginlog/index', 89, 10, '', '', 1, 1, '', 1, 0, '', '', 0, 0, 0);
INSERT INTO `zmodu_shop_access` VALUES (253, '操作日志', '/auth/optlog/index', 89, 10, '', '', 1, 1, '', 1, 0, '', '', 0, 0, 0);
INSERT INTO `zmodu_shop_access` VALUES (254, '获取手机号', '/setting/message/getphone', 52, 5, '', '', 1, 0, '', 1, 0, '', '', 0, 1597537789, 1597538411);
INSERT INTO `zmodu_shop_access` VALUES (256, '订单改价', '/order/order/updatePrice', 40, 1, '', '', 0, 0, '', 1, 0, '', '', NULL, 1598753520, 1598753520);
INSERT INTO `zmodu_shop_access` VALUES (257, '取消审核', '/order/operate/confirmCancel', 40, 1, '', '', 0, 0, '', 1, 0, '', '', NULL, 1598753587, 1598753587);
INSERT INTO `zmodu_shop_access` VALUES (258, '订单核销', '/order/operate/extract', 40, 1, '', '', 0, 0, '', 1, 0, '', '', NULL, 1598753609, 1598753609);
INSERT INTO `zmodu_shop_access` VALUES (261, '满减添加', '/plus/fullreduce/add', 260, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1599394988, 1599394988);
INSERT INTO `zmodu_shop_access` VALUES (262, '满减修改', '/plus/fullreduce/edit', 260, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1599395000, 1599395000);
INSERT INTO `zmodu_shop_access` VALUES (263, '商户', '/supplier/index', 0, 2, 'icon-supplier', '/supplier/supplier/index', 1, 1, '', 1, 0, '', '', 0, 1596090591, 1615171785);
INSERT INTO `zmodu_shop_access` VALUES (264, '商户管理', '/supplier/supplier/index', 263, 1, '', '', 1, 1, '', 1, 0, '', '', 0, 1596090719, 1615171793);
INSERT INTO `zmodu_shop_access` VALUES (265, '添加商户', '/supplier/supplier/add', 264, 1, '', '', 1, 0, '', 1, 0, '', '', 0, 1596090871, 1615171801);
INSERT INTO `zmodu_shop_access` VALUES (266, '修改商户', '/supplier/supplier/edit', 264, 1, '', '', 1, 0, '', 1, 0, '', '', 0, 1596090884, 1615171807);
INSERT INTO `zmodu_shop_access` VALUES (267, '删除商户', '/supplier/supplier/delete', 264, 1, '', '', 1, 0, '', 1, 0, '', '', 0, 1596090897, 1615171813);
INSERT INTO `zmodu_shop_access` VALUES (268, '提现管理', '/supplier/cash/index', 263, 1, '', '', 1, 1, '', 1, 0, '', '', 0, 1597637395, 1604470652);
INSERT INTO `zmodu_shop_access` VALUES (269, '入驻申请', '/supplier/supplier/apply', 263, 1, '', '', 1, 1, '', 1, 0, '', '', 0, 1604642840, 1606117602);
INSERT INTO `zmodu_shop_access` VALUES (270, '入驻审核', '/supplier/supplier/audit', 269, 1, '', '', 1, 0, '', 1, 0, '', '', 0, 1604643465, 1606119246);
INSERT INTO `zmodu_shop_access` VALUES (271, '主营类别', '/supplier/category/index', 263, 1, '', '', 1, 1, '', 1, 0, '', '', NULL, 1604892729, 1604892729);
INSERT INTO `zmodu_shop_access` VALUES (272, '添加', '/supplier/category/add', 271, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1604892794, 1604892794);
INSERT INTO `zmodu_shop_access` VALUES (273, '编辑', '/supplier/category/edit', 271, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1604892828, 1604892828);
INSERT INTO `zmodu_shop_access` VALUES (274, '删除', '/supplier/category/delete', 271, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1604892877, 1604892877);
INSERT INTO `zmodu_shop_access` VALUES (275, '拼团商品', '/plus/assemble/product/index', 132, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1605056880, 1605056880);
INSERT INTO `zmodu_shop_access` VALUES (276, '基础设置', '/plus/seckill/setting/index', 103, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1605056978, 1605056978);
INSERT INTO `zmodu_shop_access` VALUES (277, '秒杀商品', '/plus/seckill/product/index', 103, 1, '', '', 1, 0, '', 1, 0, '', '', 0, 1605056996, 1605058386);
INSERT INTO `zmodu_shop_access` VALUES (278, '编辑审核', '/plus/seckill/product/edit', 277, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1605058363, 1605058363);
INSERT INTO `zmodu_shop_access` VALUES (279, '编辑审核', '/plus/assemble/product/edit', 275, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1605064539, 1605064539);
INSERT INTO `zmodu_shop_access` VALUES (280, '砍价商品', '/plus/bargain/product/index', 104, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1605065463, 1605065463);
INSERT INTO `zmodu_shop_access` VALUES (281, '编辑审核', '/plus/bargain/product/edit', 280, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1605065493, 1605065493);
INSERT INTO `zmodu_shop_access` VALUES (282, '保证金订单', '/supplier/order/index', 263, 6, '', '', 1, 1, 'store', 1, 0, '', '', 0, 1605100115, 1606293978);
INSERT INTO `zmodu_shop_access` VALUES (1606293864, '退保证金', '/supplier/supplier/refund', 263, 7, '', '', 1, 1, 'store', 1, 0, '', '', 0, 1606293864, 1606353764);
INSERT INTO `zmodu_shop_access` VALUES (1606353689, '服务申请', '/supplier/supplier/security', 263, 9, '', '', 1, 1, 'store', 1, 0, '', '', 0, 1606353689, 1607397621);
INSERT INTO `zmodu_shop_access` VALUES (1606358382, '平台售后', '/order/platerefund/index', 39, 1, '', '', 1, 1, 'refund_refund', 1, 0, '', '', 0, 1606358382, 1606363150);
INSERT INTO `zmodu_shop_access` VALUES (1606358500, '售后详情', '/order/platerefund/detail', 1606358382, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1606358500, 1606358500);
INSERT INTO `zmodu_shop_access` VALUES (1606374122, '商户统计', '/statistics/supplier/index', 61, 1, '', '', 1, 1, '', 1, 0, '', '', 0, 1606374122, 1615171822);
INSERT INTO `zmodu_shop_access` VALUES (1606374176, '访问统计', '/statistics/access/index', 61, 1, '', '', 1, 1, '', 1, 0, '', '', 0, 1606374176, 1606374721);
INSERT INTO `zmodu_shop_access` VALUES (1606376715, '财务', '/cash', 0, 4, 'icon-caiwu', '/cash/cash/index', 1, 1, '', 1, 0, '', '', 0, 1606376715, 1606556701);
INSERT INTO `zmodu_shop_access` VALUES (1606376789, '财务概况', '/cash/cash/index', 1606376715, 1, '', '', 1, 1, '', 1, 0, '', '', 0, 1606376789, 1606439302);
INSERT INTO `zmodu_shop_access` VALUES (1606380067, '商户结算', '/cash/settled/index', 1606376715, 1, '', '', 1, 1, '', 1, 0, '', '', 0, 1606380067, 1606383979);
INSERT INTO `zmodu_shop_access` VALUES (1607394212, '服务管理', '/supplier/security/index', 263, 8, '', '', 1, 1, 'store', 1, 0, '', '', NULL, 1607394212, 1607394212);
INSERT INTO `zmodu_shop_access` VALUES (1607568329, '房间管理', '/plus/live/room/index', 250, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1607568329, 1607568329);
INSERT INTO `zmodu_shop_access` VALUES (1607568354, '房间修改', '/plus/live/room/edit', 1607568329, 1, '', '', 1, 0, '', 1, 0, '', '', 0, 1607568354, 1607568425);
INSERT INTO `zmodu_shop_access` VALUES (1607568387, '房间商品', '/plus/live/room/product', 1607568329, 1, '', '', 1, 0, '', 1, 0, '', '', 0, 1607568387, 1607568439);
INSERT INTO `zmodu_shop_access` VALUES (1607568404, '礼物排行', '/plus/live/room/user_gift', 1607568329, 1, '', '', 1, 0, '', 1, 0, '', '', 0, 1607568404, 1607568449);
INSERT INTO `zmodu_shop_access` VALUES (1607568472, '礼物设置', '/plus/live/gift/index', 250, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1607568472, 1607568472);
INSERT INTO `zmodu_shop_access` VALUES (1607568489, '礼物添加', '/plus/live/gift/add', 1607568472, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1607568489, 1607568489);
INSERT INTO `zmodu_shop_access` VALUES (1607568512, '礼物修改', '/plus/live/gift/edit', 1607568472, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1607568512, 1607568512);
INSERT INTO `zmodu_shop_access` VALUES (1607568527, '礼物删除', '/plus/live/gift/delete', 1607568472, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1607568527, 1607568527);
INSERT INTO `zmodu_shop_access` VALUES (1607568549, '直播设置', '/plus/live/setting/index', 250, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1607568549, 1607568549);
INSERT INTO `zmodu_shop_access` VALUES (1607568574, '直播订单', '/plus/live/order/list', 250, 1, '', '', 1, 0, '', 1, 0, '', '', 0, 1607568574, 1607674078);
INSERT INTO `zmodu_shop_access` VALUES (1607761913, '充值设置', '/plus/live/plan/index', 250, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1607761913, 1607761913);
INSERT INTO `zmodu_shop_access` VALUES (1607761934, '充值记录', '/plus/live/plan/log', 250, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1607761934, 1607761934);
INSERT INTO `zmodu_shop_access` VALUES (1608797350, 'app', '/appsetting/appopen/event', 85, 3, '', '', 1, 1, 'appsettings_appmp', 1, 0, '', '', 0, 1608641724, 1608781710);
INSERT INTO `zmodu_shop_access` VALUES (1608797351, '基础设置', '/appsetting/appopen/index', 1608797350, 3, '', '', 1, 1, 'appsettings_appmp', 1, 0, '', '', 0, 1608692079, 1608781716);
INSERT INTO `zmodu_shop_access` VALUES (1608797352, '分享设置', '/appsetting/appshare/index', 1608797350, 3, '', '', 1, 1, 'appsettings_appmp', 1, 0, '', '', 0, 1608692091, 1608781742);
INSERT INTO `zmodu_shop_access` VALUES (1608797353, '升级管理', '/appsetting/appupdate/index', 1608797350, 3, '', '', 1, 1, 'appsettings_appmp', 1, 0, '', '', 0, 1608778225, 1608781753);
INSERT INTO `zmodu_shop_access` VALUES (1608797354, '升级新增', '/appsetting/appupdate/add', 1608797353, 3, '', '', 0, 1, 'appsettings_appmp', 1, 0, '', '', NULL, 1608781938, 1608781938);
INSERT INTO `zmodu_shop_access` VALUES (1608797355, '升级修改', '/appsetting/appupdate/edit', 1608797353, 3, '', '', 0, 1, 'appsettings_appmp', 1, 0, '', '', NULL, 1608781950, 1608781950);
INSERT INTO `zmodu_shop_access` VALUES (1608797356, '升级删除', '/appsetting/appupdate/delete', 1608797353, 3, '', '', 0, 1, 'appsettings_appmp', 1, 0, '', '', NULL, 1608781963, 1608781963);
INSERT INTO `zmodu_shop_access` VALUES (1608859789, '底部导航', '/page/page/nav', 71, 3, '', '', 1, 1, '', 0, 0, '', '', NULL, 1608859789, 1619588244);
INSERT INTO `zmodu_shop_access` VALUES (1611737214, '支付设置', '/appsetting/apph5/pay', 1611737154, 3, '', '', 1, 1, 'appsettings_appmp', 1, 0, '', '', 0, 1611737214, 1611737797);
INSERT INTO `zmodu_shop_access` VALUES (1614308384, '底部菜单', '/page/page/bottomnav', 71, 4, '', '', 1, 1, '', 1, 0, '', '', 0, 1614308384, 1614308400);
INSERT INTO `zmodu_shop_access` VALUES (1614997697, '满减删除', '/plus/fullreduce/delete', 260, 1, '', '', 0, 0, '', 1, 0, '', '', NULL, 1606283461, 1606283461);
INSERT INTO `zmodu_shop_access` VALUES (1615015378, '订单物流', '/order/order/express', 40, 1, '', '', 0, 0, '', 1, 0, '', '', NULL, 1615015378, 1615015378);
INSERT INTO `zmodu_shop_access` VALUES (1615016374, '订单改地址', '/order/order/updateAddress', 40, 1, '', '', 0, 0, '', 1, 0, '', '', NULL, 1615016374, 1615016374);
INSERT INTO `zmodu_shop_access` VALUES (1627268726, '菜单修改', '/page/page/bottomedit', 1614308384, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1627268726, 1627268726);
INSERT INTO `zmodu_shop_access` VALUES (1627553916, '标签管理', '/user/tag/index', 54, 2, '', '', 1, 1, '', 1, 0, '', '', 0, 1627553916, 1627554389);
INSERT INTO `zmodu_shop_access` VALUES (1627553945, '添加标签', '/user/tag/add', 1627553916, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1627553945, 1627553945);
INSERT INTO `zmodu_shop_access` VALUES (1627553967, '修改标签', '/user/tag/edit', 1627553916, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1627553967, 1627553967);
INSERT INTO `zmodu_shop_access` VALUES (1627553983, '删除标签', '/user/tag/delete', 1627553916, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1627553983, 1627553983);
INSERT INTO `zmodu_shop_access` VALUES (1628828907, '会员标签', '/user/user/tag', 55, 4, '', '', 1, 0, '', 1, 0, '', '', NULL, 1628828907, 1628828907);
INSERT INTO `zmodu_shop_access` VALUES (1630898878, '转盘抽奖', '/plus/lottery/index', 74, 10, 'icon-choujiangLottery', '', 1, 0, 'plus_bargain_index', 1, 2, '积分抽奖兑换好礼', '', 0, 1630898878, 1630923567);
INSERT INTO `zmodu_shop_access` VALUES (1630898903, '转盘设置', '/plus/lottery/setting', 1630898878, 1, '', '', 1, 0, '', 1, 0, '', '', 0, 1630898903, 1630898919);
INSERT INTO `zmodu_shop_access` VALUES (1630898935, '转盘记录', '/plus/lottery/record', 1630898878, 2, '', '', 1, 0, '', 1, 0, '', '', NULL, 1630898935, 1630898935);
INSERT INTO `zmodu_shop_access` VALUES (1630910783, '万能表单', '/plus/table/event', 74, 10, 'icon-quanbudingdan', '', 1, 1, 'plus_fullfree_index', 1, 1, '万能表单按需收集信息', '', 0, 1630910783, 1630911923);
INSERT INTO `zmodu_shop_access` VALUES (1630910901, '表单管理', '/plus/table/table/index', 1630910783, 1, '', '', 1, 0, '', 1, 0, '', '', 0, 1630910901, 1630911060);
INSERT INTO `zmodu_shop_access` VALUES (1630910912, '表单记录', '/plus/table/record/index', 1630910783, 1, '', '', 1, 0, '', 1, 0, '', '', 0, 1630910912, 1630911040);
INSERT INTO `zmodu_shop_access` VALUES (1630910960, '表单添加', '/plus/table/table/add', 1630910901, 1, '', '', 1, 0, '', 1, 0, '', '', 0, 1630910960, 1630911067);
INSERT INTO `zmodu_shop_access` VALUES (1630910972, '表单修改', '/plus/table/table/edit', 1630910901, 1, '', '', 1, 0, '', 1, 0, '', '', 0, 1630910972, 1630911075);
INSERT INTO `zmodu_shop_access` VALUES (1630910983, '表单删除', '/plus/table/table/delete', 1630910901, 1, '', '', 1, 0, '', 1, 0, '', '', 0, 1630910983, 1630911083);
INSERT INTO `zmodu_shop_access` VALUES (1630911031, '记录删除', '/plus/table/record/delete', 1630910912, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1630911031, 1630911031);
INSERT INTO `zmodu_shop_access` VALUES (1634269820, '分销商等级', '/plus/agent/grade/index', 99, 1, '', '', 0, 0, '', 1, 0, '', '', NULL, 1634269820, 1634269820);
INSERT INTO `zmodu_shop_access` VALUES (1634269856, '添加等级', '/plus/agent/grade/add', 1634269820, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1634269856, 1634269856);
INSERT INTO `zmodu_shop_access` VALUES (1634269872, '编辑等级', '/plus/agent/grade/edit', 1634269820, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1634269872, 1634269872);
INSERT INTO `zmodu_shop_access` VALUES (1634539570, '删除等级', '/plus/agent/grade/delete', 1634269820, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1634539570, 1634539570);
INSERT INTO `zmodu_shop_access` VALUES (1642821889, '导出', '/plus/agent/order/export', 218, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1642821889, 1642821889);
INSERT INTO `zmodu_shop_access` VALUES (1642821903, '导出', '/plus/agent/cash/export', 219, 1, '', '', 0, 0, '', 1, 0, '', '', NULL, 1642821903, 1642821903);
INSERT INTO `zmodu_shop_access` VALUES (1646105229, '首页装修', '/page/page/list', 71, 1, '', '', 1, 1, 'page_home', 1, 0, '', '', 0, 1646105229, 1646120158);
INSERT INTO `zmodu_shop_access` VALUES (1646120244, '添加', '/page/page/addPage', 1646105229, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1646120244, 1646120244);
INSERT INTO `zmodu_shop_access` VALUES (1646120257, '编辑', '/page/page/editPage', 1646105229, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1646120257, 1646120257);
INSERT INTO `zmodu_shop_access` VALUES (1646120284, '删除', '/page/page/deletePage', 1646105229, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1646120284, 1646120284);
INSERT INTO `zmodu_shop_access` VALUES (1646120351, '设为首页', '/page/page/setPage', 1646105229, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1646120351, 1646120351);
INSERT INTO `zmodu_shop_access` VALUES (1646292411, '主题设置', '/page/theme/index', 71, 3, '', '', 1, 1, '', 1, 0, '', '', NULL, 1646292411, 1646292411);
INSERT INTO `zmodu_shop_access` VALUES (1650878164, '支付设置', '/appsetting/app/pay', 85, 3, '', '', 1, 1, 'appsettings_appmp', 1, 0, '', '', NULL, 1650878164, 1650878164);
INSERT INTO `zmodu_shop_access` VALUES (1654760896, '提现设置', '/user/cash/setting', 120, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1654760896, 1654760896);
INSERT INTO `zmodu_shop_access` VALUES (1654760925, '提现记录', '/user/cash/index', 120, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1654760925, 1654760925);
INSERT INTO `zmodu_shop_access` VALUES (1654760941, '提现审核', '/user/cash/audit', 120, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1654760941, 1654760941);
INSERT INTO `zmodu_shop_access` VALUES (1654760955, '确认打款', '/user/cash/money', 120, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1654760955, 1654760955);
INSERT INTO `zmodu_shop_access` VALUES (1654760973, '微信付款', '/user/cash/wxpay', 120, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1654760973, 1654760973);
INSERT INTO `zmodu_shop_access` VALUES (1654760987, '提现导出', '/user/cash/export', 120, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1654760987, 1654760987);
INSERT INTO `zmodu_shop_access` VALUES (1654764619, '预售活动', '/plus/advance/index', 74, 10, 'icon-manjian', '', 1, 1, 'plus_fullfree_index', 1, 2, '预售活动、提前锁定客源', '', NULL, 1654764619, 1654764619);
INSERT INTO `zmodu_shop_access` VALUES (1654765208, '预售商品', '/plus/advance/product/index', 1654764619, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1654765208, 1654765208);
INSERT INTO `zmodu_shop_access` VALUES (1654765249, '审核', '/plus/advance/product/edit', 1654765208, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1654765249, 1654765249);
INSERT INTO `zmodu_shop_access` VALUES (1654765261, '删除', '/plus/advance/product/delete', 1654765208, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1654765261, 1654765261);
INSERT INTO `zmodu_shop_access` VALUES (1654765402, '设置', '/plus/advance/setting/index', 1654764619, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1654765402, 1654765402);
INSERT INTO `zmodu_shop_access` VALUES (1656381879, '审核评价', '/product/comment/edit', 122, 2, '', '', 1, 0, 'comment|_delete', 1, 0, '', '', NULL, 1656381879, 1656381879);
INSERT INTO `zmodu_shop_access` VALUES (1656386579, '订单导出', '/order/operate/export', 40, 1, '', '', 0, 0, '', 1, 0, '', '', NULL, 1656386579, 1656386579);
INSERT INTO `zmodu_shop_access` VALUES (1656387809, '售后审核', '/order/platerefund/audit', 1606358382, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656387809, 1656387809);
INSERT INTO `zmodu_shop_access` VALUES (1656387869, '升级日志', '/user/grade/log', 56, 3, '', '', 1, 0, '/member/grade/delete', 1, 0, '', '', NULL, 1656387869, 1656387869);
INSERT INTO `zmodu_shop_access` VALUES (1656388641, '积分设置', '/user/points/setting', 96, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656388641, 1656388641);
INSERT INTO `zmodu_shop_access` VALUES (1656388671, '积分明细', '/user/points/log', 96, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656388671, 1656388671);
INSERT INTO `zmodu_shop_access` VALUES (1656388735, '余额明细', '/user/balance/log', 120, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656388735, 1656388735);
INSERT INTO `zmodu_shop_access` VALUES (1656395150, '充值设置', '/user/balance/setting', 120, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656395150, 1656395150);
INSERT INTO `zmodu_shop_access` VALUES (1656395243, '充值套餐', '/user/plan/index', 120, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656395243, 1656395243);
INSERT INTO `zmodu_shop_access` VALUES (1656395301, '添加套餐', '/user/plan/add', 1656395243, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656395301, 1656395301);
INSERT INTO `zmodu_shop_access` VALUES (1656395316, '编辑套餐', '/user/plan/edit', 1656395243, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656395316, 1656395316);
INSERT INTO `zmodu_shop_access` VALUES (1656395476, '删除套餐', '/user/plan/delete', 1656395243, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656395476, 1656395476);
INSERT INTO `zmodu_shop_access` VALUES (1656395501, '充值记录', '/user/plan/log', 1656395243, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656395501, 1656395501);
INSERT INTO `zmodu_shop_access` VALUES (1656399572, '开启禁用商户', '/supplier/supplier/recycle', 264, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656399572, 1656399572);
INSERT INTO `zmodu_shop_access` VALUES (1656400110, '提现审核', '/supplier/cash/submit', 268, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656400110, 1656400110);
INSERT INTO `zmodu_shop_access` VALUES (1656400126, '确认打款', '/supplier/cash/money', 268, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656400126, 1656400126);
INSERT INTO `zmodu_shop_access` VALUES (1656400524, '添加服务', '/supplier/security/add', 1607394212, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656400524, 1656400524);
INSERT INTO `zmodu_shop_access` VALUES (1656400536, '编辑服务', '/supplier/security/edit', 1607394212, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656400536, 1656400536);
INSERT INTO `zmodu_shop_access` VALUES (1656400550, '删除服务', '/supplier/security/delete', 1607394212, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656400550, 1656400550);
INSERT INTO `zmodu_shop_access` VALUES (1656400637, '审核', '/supplier/supplier/verify', 1606353689, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656400637, 1656400637);
INSERT INTO `zmodu_shop_access` VALUES (1656400847, '统计曲线图', '/statistics/supplier/data', 1606374122, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656400847, 1656400847);
INSERT INTO `zmodu_shop_access` VALUES (1656400877, '统计曲线图', '/statistics/access/data', 1606374176, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656400877, 1656400877);
INSERT INTO `zmodu_shop_access` VALUES (1656401238, '详情', '/setting/message/field', 78, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656401238, 1656401238);
INSERT INTO `zmodu_shop_access` VALUES (1656401276, '编辑', '/setting/message/saveSettings', 78, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656401276, 1656401276);
INSERT INTO `zmodu_shop_access` VALUES (1656401326, '启用设置', '/setting/message/updateSettingsStatus', 78, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656401326, 1656401326);
INSERT INTO `zmodu_shop_access` VALUES (1656402101, '升级日志', '/plus/agent/grade/log', 1634269820, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656402101, 1656402101);
INSERT INTO `zmodu_shop_access` VALUES (1656402178, '微信打款', '/plus/agent/cash/wechat_pay', 219, 1, '', '', 0, 0, '', 1, 0, '', '', NULL, 1656402178, 1656402178);
INSERT INTO `zmodu_shop_access` VALUES (1656402278, '基础设置', '/plus/agent/setting/basic', 220, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656402278, 1656402278);
INSERT INTO `zmodu_shop_access` VALUES (1656402338, '佣金设置', '/plus/agent/setting/commission', 220, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656402338, 1656402338);
INSERT INTO `zmodu_shop_access` VALUES (1656402360, '结算设置', '/plus/agent/setting/settlement', 220, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656402360, 1656402360);
INSERT INTO `zmodu_shop_access` VALUES (1656402384, '自定义文字设置', '/plus/agent/setting/words', 220, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656402384, 1656402384);
INSERT INTO `zmodu_shop_access` VALUES (1656402408, '申请协议设置', '/plus/agent/setting/license', 220, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656402408, 1656402408);
INSERT INTO `zmodu_shop_access` VALUES (1656402431, '页面背景图设置', '/plus/agent/setting/background', 220, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656402431, 1656402431);
INSERT INTO `zmodu_shop_access` VALUES (1656402515, '删除活动', '/plus/seckill/active/delete', 245, 4, '', '', 1, 1, 'plus_seckill_active_Edit', 1, 0, '', '', NULL, 1656402515, 1656402515);
INSERT INTO `zmodu_shop_access` VALUES (1656403008, '活动审核删除', '/plus/seckill/product/delete', 277, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656403008, 1656403008);
INSERT INTO `zmodu_shop_access` VALUES (1656403475, '审核记录删除', '/plus/assemble/product/delete', 275, 1, '', '', 1, 0, '', 1, 0, '', '', 0, 1656403475, 1656403828);
INSERT INTO `zmodu_shop_access` VALUES (1656403811, '审核记录删除', '/plus/bargain/product/delete', 280, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656403811, 1656403811);
INSERT INTO `zmodu_shop_access` VALUES (1656404533, '添加', '/plus/live/plan/add', 1607761913, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656404533, 1656404533);
INSERT INTO `zmodu_shop_access` VALUES (1656404542, '编辑', '/plus/live/plan/edit', 1607761913, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656404542, 1656404542);
INSERT INTO `zmodu_shop_access` VALUES (1656404561, '删除', '/plus/live/plan/delete', 1607761913, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656404561, 1656404561);
INSERT INTO `zmodu_shop_access` VALUES (1666683397, '会员等级', '/user/user/grade', 55, 4, '', '', 1, 0, '', 1, 0, '', '', NULL, 1666683397, 1666683397);
INSERT INTO `zmodu_shop_access` VALUES (1668064853, '任务中心', '/plus/task/index', 74, 10, 'icon-renwu', '', 1, 1, 'plus_fullfree_index', 1, 2, '任务多多、福利多多', '', NULL, 1668064853, 1668064853);
INSERT INTO `zmodu_shop_access` VALUES (1668132559, '商品状态', '/product/product/state', 15, 4, '', '', 1, 0, 'product_copy', 1, 0, '', '', 0, 1668132559, 1668132635);
INSERT INTO `zmodu_shop_access` VALUES (1668154670, '商品上下架', '/plus/points/product/state', 215, 4, '', '', 1, 0, 'plus_point_product_del', 1, 0, '', '', NULL, 1668154670, 1668154670);
INSERT INTO `zmodu_shop_access` VALUES (1668154718, '商品上下架', '/plus/seckill/product/state', 277, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1668154718, 1668154718);
INSERT INTO `zmodu_shop_access` VALUES (1668154742, '商品上下架', '/plus/assemble/product/state', 275, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1668154742, 1668154742);
INSERT INTO `zmodu_shop_access` VALUES (1668154823, '商品上下架', '/plus/bargain/product/state', 280, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1668154823, 1668154823);
INSERT INTO `zmodu_shop_access` VALUES (1685504955, '发放', '/plus/lottery/send', 1630898935, 1, '', '', 1, 0, '', 1, 0, '', '', 0, 1685504955, 1685514420);
INSERT INTO `zmodu_shop_access` VALUES (1685504966, '详情', '/plus/lottery/detail', 1630898935, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1685504966, 1685504966);
INSERT INTO `zmodu_shop_access` VALUES (1685687134, '导出', '/plus/lottery/export', 1630898935, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1685687134, 1685687134);
INSERT INTO `zmodu_shop_access` VALUES (1698976609, '个人中心', '/page/center/index', 71, 5, '', '', 1, 1, '', 1, 0, '', '', NULL, 1698976609, 1698976609);
INSERT INTO `zmodu_shop_access` VALUES (1698976624, '添加', '/page/center/add', 1698976609, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1698976624, 1698976624);
INSERT INTO `zmodu_shop_access` VALUES (1698976637, '编辑', '/page/center/edit', 1698976609, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1698976637, 1698976637);
INSERT INTO `zmodu_shop_access` VALUES (1698976652, '删除', '/page/center/delete', 1698976609, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1698976652, 1698976652);
INSERT INTO `zmodu_shop_access` VALUES (1698976670, '设置默认', '/page/center/set', 1698976609, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1698976670, 1698976670);
INSERT INTO `zmodu_shop_access` VALUES (1699000827, '分销商品', '/plus/agent/product/index', 99, 1, '', '', 0, 0, '', 1, 0, '', '', NULL, 1699000827, 1699000827);
INSERT INTO `zmodu_shop_access` VALUES (1699000850, '详情', '/plus/agent/product/detail', 1699000827, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1699000850, 1699000850);
INSERT INTO `zmodu_shop_access` VALUES (1699238566, '客服', '/chat', 0, 4, 'icon-kefu', '/chat/chat/index', 1, 1, 'statistics', 1, 0, '', '', NULL, 1699238566, 1699238566);
INSERT INTO `zmodu_shop_access` VALUES (1699238597, '客服列表', '/chat/chat/index', 1699238566, 1, '', '', 1, 1, '', 1, 0, '', '', NULL, 1699238597, 1699238597);
INSERT INTO `zmodu_shop_access` VALUES (1699238714, '添加', '/chat/chat/add', 1699238597, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1699238714, 1699238714);
INSERT INTO `zmodu_shop_access` VALUES (1699238746, '编辑', '/chat/chat/edit', 1699238597, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1699238746, 1699238746);
INSERT INTO `zmodu_shop_access` VALUES (1699238765, '删除', '/chat/chat/delete', 1699238597, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1699238765, 1699238765);
INSERT INTO `zmodu_shop_access` VALUES (1699238802, '状态设置', '/chat/chat/set', 1699238597, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1699238802, 1699238802);
INSERT INTO `zmodu_shop_access` VALUES (1699238833, '聊天记录', '/chat/chat/list', 1699238597, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1699238833, 1699238833);
INSERT INTO `zmodu_shop_access` VALUES (1699238878, '对话记录', '/chat/chat/record', 1699238833, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1699238878, 1699238878);
INSERT INTO `zmodu_shop_access` VALUES (1699500947, '结算详情', '/cash/settled/detail', 1606380067, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1699500947, 1699500947);
INSERT INTO `zmodu_shop_access` VALUES (1705281254, '状态', '/product/category/set', 42, 3, '', '', 1, 0, 'category_delete', 1, 0, '', '', NULL, 1705281254, 1705281254);
INSERT INTO `zmodu_shop_access` VALUES (1705284348, '面单模板', '/setting/template/index', 52, 4, '', '', 1, 1, 'setting_express_index', 1, 0, '', '', NULL, 1705284348, 1705284348);
INSERT INTO `zmodu_shop_access` VALUES (1705288296, '添加', '/setting/template/add', 1705284348, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1705288296, 1705288296);
INSERT INTO `zmodu_shop_access` VALUES (1705288306, '编辑', '/setting/template/edit', 1705284348, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1705288306, 1705288306);
INSERT INTO `zmodu_shop_access` VALUES (1705288324, '删除', '/setting/template/delete', 1705284348, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1705288324, 1705288324);
INSERT INTO `zmodu_shop_access` VALUES (1716974916, '协议设置', '/setting/protocol/index', 52, 10, '', '', 1, 1, 'setting_storage', 1, 0, '', '', NULL, 1716974916, 1716974916);
INSERT INTO `zmodu_shop_access` VALUES (1719215273, '导出', '/plus/table/record/export', 1630910912, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1719215273, 1719215273);
INSERT INTO `zmodu_shop_access` VALUES (1719536687, '添加会员', '/user/user/add', 55, 5, '', '', 1, 0, '', 1, 0, '', '', NULL, 1719536687, 1719536687);
INSERT INTO `zmodu_shop_access` VALUES (1720770456, '审核', '/plus/live/room/audit', 1607568329, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1720770456, 1720770463);
INSERT INTO `zmodu_shop_access` VALUES (1735957282, '备注', '/plus/lottery/remark', 1630898935, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1735957282, 1735957282);
INSERT INTO `zmodu_shop_access` VALUES (1735957306, '物流信息', '/plus/lottery/express', 1630898935, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1735957306, 1735957306);
INSERT INTO `zmodu_shop_access` VALUES (1741401924, '撤销微信付款', '/user/cash/cancel', 120, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1741401924, 1741401924);
INSERT INTO `zmodu_shop_access` VALUES (1741401964, '撤销微信付款', '/plus/agent/cash/cancel', 219, 1, '', '', 0, 0, '', 1, 0, '', '', NULL, 1741401964, 1741401964);
INSERT INTO `zmodu_shop_access` VALUES (1741418923, '买送活动', '/plus/buyactivity/index', 74, 10, 'icon-libao', '', 1, 1, 'plus_fullfree_index', 1, 2, '购买即送，吸引客户，促进消费', '', NULL, 1741418923, 1741420019);
INSERT INTO `zmodu_shop_access` VALUES (1741418954, '编辑审核', '/plus/buyactivity/edit', 1741418923, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1741418954, 1741418954);
INSERT INTO `zmodu_shop_access` VALUES (1741418967, '删除', '/plus/buyactivity/delete', 1741418923, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1741418967, 1741418967);
INSERT INTO `zmodu_shop_access` VALUES (1741423108, '状态', '/plus/buyactivity/state', 1741418923, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1741423108, 1741423108);
INSERT INTO `zmodu_shop_access` VALUES (1749715989, '添加', '/plus/agent/poster/add', 221, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1749715989, 1749715989);
INSERT INTO `zmodu_shop_access` VALUES (1749716011, '编辑', '/plus/agent/poster/edit', 221, 2, '', '', 1, 0, '', 1, 0, '', '', NULL, 1749716011, 1749716011);
INSERT INTO `zmodu_shop_access` VALUES (1749716026, '状态', '/plus/agent/poster/state', 221, 2, '', '', 1, 0, '', 1, 0, '', '', NULL, 1749716026, 1749716026);
INSERT INTO `zmodu_shop_access` VALUES (1749716039, '删除', '/plus/agent/poster/delete', 221, 2, '', '', 1, 0, '', 1, 0, '', '', NULL, 1749716039, 1749716039);
INSERT INTO `zmodu_shop_access` VALUES (1749716051, '预览', '/plus/agent/poster/preview', 221, 2, '', '', 1, 0, '', 1, 0, '', '', NULL, 1749716051, 1749716051);
INSERT INTO `zmodu_shop_access` VALUES (1749723274, '等级任务', '/plus/agent/task/index', 1634269820, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1749723274, 1749723274);
INSERT INTO `zmodu_shop_access` VALUES (1749723327, '添加任务', '/plus/agent/task/add', 1749723274, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1749723327, 1749723327);
INSERT INTO `zmodu_shop_access` VALUES (1749723344, '编辑任务', '/plus/agent/task/edit', 1749723274, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1749723344, 1749723344);
INSERT INTO `zmodu_shop_access` VALUES (1749723358, '设置状态', '/plus/agent/task/state', 1749723274, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1749723358, 1749723358);
INSERT INTO `zmodu_shop_access` VALUES (1749723372, '删除任务', '/plus/agent/task/delete', 1749723274, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1749723372, 1749723372);
INSERT INTO `zmodu_shop_access` VALUES (1749796003, '新增', '/plus/agent/user/add', 217, 1, '', '', 0, 0, '', 1, 0, '', '', NULL, 1749796003, 1749796018);
INSERT INTO `zmodu_shop_access` VALUES (1750060213, '等级权益', '/user/equity/index', 54, 5, '', '', 1, 1, 'member_log', 1, 0, '', '', NULL, 1750060213, 1750060213);
INSERT INTO `zmodu_shop_access` VALUES (1750060230, '添加', '/user/equity/add', 1750060213, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1750060230, 1750060230);
INSERT INTO `zmodu_shop_access` VALUES (1750060244, '编辑', '/user/equity/edit', 1750060213, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1750060244, 1750060244);
INSERT INTO `zmodu_shop_access` VALUES (1750060258, '删除', '/user/equity/delete', 1750060213, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1750060258, 1750060258);
INSERT INTO `zmodu_shop_access` VALUES (1752816983, '秒杀配置', '/plus/seckill/time/index', 103, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1752816983, 1752816983);
INSERT INTO `zmodu_shop_access` VALUES (1752817038, '添加', '/plus/seckill/time/add', 1752816983, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1752817038, 1752817038);
INSERT INTO `zmodu_shop_access` VALUES (1752817075, '编辑', '/plus/seckill/time/edit', 1752816983, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1752817075, 1752817075);
INSERT INTO `zmodu_shop_access` VALUES (1752817091, '删除', '/plus/seckill/time/delete', 1752816983, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1752817091, 1752817091);
INSERT INTO `zmodu_shop_access` VALUES (1752817108, '设置状态', '/plus/seckill/time/state', 1752816983, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1752817108, 1752817108);
INSERT INTO `zmodu_shop_access` VALUES (1752823893, '设置状态', '/plus/seckill/active/state', 245, 4, '', '', 1, 1, 'plus_seckill_active_Edit', 1, 0, '', '', NULL, 1752823893, 1752823893);
INSERT INTO `zmodu_shop_access` VALUES (1752828417, '统计', '/plus/seckill/product/statistics', 277, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1752828417, 1752828417);
INSERT INTO `zmodu_shop_access` VALUES (1752828443, '参与人', '/plus/seckill/product/join', 1752828417, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1752828443, 1752828443);
INSERT INTO `zmodu_shop_access` VALUES (1752828462, '活动订单', '/plus/seckill/product/order', 1752828417, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1752828462, 1752828462);
INSERT INTO `zmodu_shop_access` VALUES (1757918691, '卡密管理', '/product/virtual/index', 15, 6, '', '', 1, 0, 'product_copy', 1, 0, '', '', NULL, 1757918691, 1758188168);
INSERT INTO `zmodu_shop_access` VALUES (1757918723, '添加', '/product/virtual/add', 1757918691, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1757918723, 1757923359);
INSERT INTO `zmodu_shop_access` VALUES (1757923374, '编辑', '/product/virtual/edit', 1757918691, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1757923374, 1757923374);
INSERT INTO `zmodu_shop_access` VALUES (1757923389, '删除', '/product/virtual/delete', 1757918691, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1757923389, 1757923389);
INSERT INTO `zmodu_shop_access` VALUES (1757923409, '查看订单', '/product/virtual/order', 1757918691, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1757923409, 1757923409);
INSERT INTO `zmodu_shop_access` VALUES (1758188149, '导入卡密', '/product/product/importVirtual', 15, 5, '', '', 1, 0, 'product_copy', 1, 0, '', '', NULL, 1758188149, 1758188175);
INSERT INTO `zmodu_shop_access` VALUES (1762138801, '统计', '/plus/assemble/product/statistics', 275, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1762138801, 1762138801);
INSERT INTO `zmodu_shop_access` VALUES (1762138873, '参与人', '/plus/assemble/product/join', 1762138801, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1762138873, 1762138873);
INSERT INTO `zmodu_shop_access` VALUES (1762138899, '详情', '/plus/assemble/product/detail', 1762138873, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1762138899, 1762138899);
INSERT INTO `zmodu_shop_access` VALUES (1762138916, '活动订单', '/plus/assemble/product/order', 1762138801, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1762138916, 1762138916);
INSERT INTO `zmodu_shop_access` VALUES (1762139048, '拼团列表', '/plus/assemble/record/index', 132, 2, '', '', 1, 0, '', 1, 0, '', '', NULL, 1762139048, 1762139048);
INSERT INTO `zmodu_shop_access` VALUES (1762139067, '详情', '/plus/assemble/record/detail', 1762139048, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1762139067, 1762139067);
INSERT INTO `zmodu_shop_access` VALUES (1762151596, '统计', '/plus/bargain/product/statistics', 280, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1762151596, 1762151596);
INSERT INTO `zmodu_shop_access` VALUES (1762151621, '参与人', '/plus/bargain/product/join', 1762151596, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1762151621, 1762151621);
INSERT INTO `zmodu_shop_access` VALUES (1762151649, '详情', '/plus/bargain/product/detail', 1762151621, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1762151649, 1762151649);
INSERT INTO `zmodu_shop_access` VALUES (1762151683, '活动订单', '/plus/bargain/product/order', 1762151596, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1762151683, 1762151683);
INSERT INTO `zmodu_shop_access` VALUES (1762163864, '基础设置', '/plus/coupon/setting/index', 97, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1762163864, 1762163864);
INSERT INTO `zmodu_shop_access` VALUES (1763082847, '注册有礼', '/plus/register/index', 74, 10, 'icon-quanxianguanli', '', 1, 1, 'plus_fullfree_index', 1, 2, '新人注册获取多重好礼', '', NULL, 1763082847, 1763082847);

-- ----------------------------
-- Table structure for zmodu_shop_fullreduce
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_shop_fullreduce`;
CREATE TABLE `zmodu_shop_fullreduce`  (
  `fullreduce_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `active_name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '活动名称',
  `full_type` tinyint(3) UNSIGNED NOT NULL DEFAULT 1 COMMENT '满类型1，满额2，满件数',
  `full_value` int(11) NULL DEFAULT 0 COMMENT '满值',
  `reduce_type` tinyint(4) NULL DEFAULT 1 COMMENT '减类型，1，减金额 2，打折',
  `reduce_value` int(11) NULL DEFAULT 0 COMMENT '减值',
  `product_id` int(11) NULL DEFAULT 0 COMMENT '商品id',
  `is_delete` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '0=显示1=伪删除',
  `shop_supplier_id` int(11) NOT NULL DEFAULT 0 COMMENT '商户id',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(11) NOT NULL COMMENT '更新时间',
  PRIMARY KEY (`fullreduce_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '满减设置表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_shop_fullreduce
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_shop_login_log
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_shop_login_log`;
CREATE TABLE `zmodu_shop_login_log`  (
  `login_log_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `username` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '用户名',
  `ip` varchar(128) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '登录ip',
  `result` varchar(128) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '登录结果',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '签到时间',
  PRIMARY KEY (`login_log_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '管理员登录记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_shop_login_log
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_shop_opt_log
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_shop_opt_log`;
CREATE TABLE `zmodu_shop_opt_log`  (
  `opt_log_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `shop_user_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '用户id',
  `title` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '标题',
  `url` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '访问url',
  `request_type` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '请求类型',
  `browser` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '浏览器',
  `agent` varchar(500) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '浏览器信息',
  `content` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NULL COMMENT '操作内容',
  `ip` varchar(128) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '登录ip',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '签到时间',
  PRIMARY KEY (`opt_log_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '管理员操作记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_shop_opt_log
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_shop_role
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_shop_role`;
CREATE TABLE `zmodu_shop_role`  (
  `role_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '角色id',
  `role_name` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '角色名称',
  `sort` int(10) UNSIGNED NOT NULL DEFAULT 100 COMMENT '排序(数字越小越靠前)',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`role_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '商家用户角色表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_shop_role
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_shop_role_access
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_shop_role_access`;
CREATE TABLE `zmodu_shop_role_access`  (
  `id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `role_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '角色id',
  `access_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '权限id',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  PRIMARY KEY (`id`) USING BTREE,
  INDEX `role_id`(`role_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '商家用户角色权限关系表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_shop_role_access
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_shop_user
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_shop_user`;
CREATE TABLE `zmodu_shop_user`  (
  `shop_user_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `user_name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '用户名',
  `password` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '登录密码',
  `real_name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '姓名',
  `is_super` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否为超级管理员0不是,1是',
  `is_delete` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '0=显示1=伪删除',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(11) NOT NULL COMMENT '更新时间',
  PRIMARY KEY (`shop_user_id`) USING BTREE,
  INDEX `user_name`(`user_name`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 10002 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '商家用户记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_shop_user
-- ----------------------------
INSERT INTO `zmodu_shop_user` VALUES (10001, 'admin', '06e0213dcf92e986d383029494966903', '管理员', 1, 0, 10001, 1529926348, 1599352830);

-- ----------------------------
-- Table structure for zmodu_shop_user_role
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_shop_user_role`;
CREATE TABLE `zmodu_shop_user_role`  (
  `id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `shop_user_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '超管用户id',
  `role_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '角色id',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`id`) USING BTREE,
  INDEX `admin_user_id`(`shop_user_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '商家用户角色记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_shop_user_role
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_sms
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_sms`;
CREATE TABLE `zmodu_sms`  (
  `sms_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `mobile` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '手机号',
  `code` varchar(128) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '验证码',
  `sence` varchar(128) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '场景,login，apply',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '签到时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`sms_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '用户注册短信表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_sms
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_spec
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_spec`;
CREATE TABLE `zmodu_spec`  (
  `spec_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '规格组id',
  `spec_name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '规格组名称',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '应用id',
  `create_time` int(11) NOT NULL COMMENT '创建时间',
  PRIMARY KEY (`spec_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '商品规格组记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_spec
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_spec_value
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_spec_value`;
CREATE TABLE `zmodu_spec_value`  (
  `spec_value_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '规格值id',
  `spec_value` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL COMMENT '规格值',
  `spec_id` int(11) NOT NULL COMMENT '规格组id',
  `app_id` int(11) NOT NULL COMMENT '应用id',
  `create_time` int(11) NOT NULL COMMENT '创建时间',
  PRIMARY KEY (`spec_value_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '商品规格值记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_spec_value
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_store
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_store`;
CREATE TABLE `zmodu_store`  (
  `store_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '门店id',
  `store_name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '门店名称',
  `logo_image_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '门店logo图片id',
  `linkman` varchar(20) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '联系人',
  `phone` varchar(20) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '联系电话',
  `shop_hours` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '营业时间',
  `province_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '所在省份id',
  `city_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '所在城市id',
  `region_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '所在辖区id',
  `address` varchar(100) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '详细地址',
  `longitude` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '门店坐标经度',
  `latitude` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '门店坐标纬度',
  `geohash` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT 'geohash',
  `summary` varchar(1000) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '0' COMMENT '门店简介',
  `sort` tinyint(4) NOT NULL DEFAULT 0 COMMENT '门店排序(数字越小越靠前)',
  `is_check` tinyint(3) UNSIGNED NOT NULL DEFAULT 1 COMMENT '是否支持自提核销(0否 1支持)',
  `status` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '门店状态(0禁用 1启用)',
  `shop_supplier_id` int(11) NULL DEFAULT 0 COMMENT '供应商id',
  `is_delete` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否删除',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(11) NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(11) NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`store_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '商家门店记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_store
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_store_clerk
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_store_clerk`;
CREATE TABLE `zmodu_store_clerk`  (
  `clerk_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '店员id',
  `store_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '所属门店id',
  `user_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '用户id',
  `real_name` varchar(30) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '店员姓名',
  `mobile` varchar(20) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '手机号',
  `status` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '状态(0禁用 1启用)',
  `shop_supplier_id` int(11) NOT NULL COMMENT '商户id',
  `is_delete` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否删除',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(11) NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(11) NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`clerk_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '商家门店店员表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_store_clerk
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_store_order
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_store_order`;
CREATE TABLE `zmodu_store_order`  (
  `id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `order_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '订单id',
  `order_type` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '订单类型(10商城订单)',
  `store_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '门店id',
  `clerk_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '核销员id',
  `shop_supplier_id` int(11) NOT NULL COMMENT '商户id',
  `verify_num` int(11) NOT NULL DEFAULT 0 COMMENT '核销次数',
  `verify_status` tinyint(3) NOT NULL DEFAULT 10 COMMENT '核销状态10成功20已取消',
  `cancel_time` int(11) NOT NULL DEFAULT 0 COMMENT '取消时间',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(11) NOT NULL DEFAULT 0 COMMENT '创建时间',
  PRIMARY KEY (`id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '商家门店核销订单记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_store_order
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_supplier
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_supplier`;
CREATE TABLE `zmodu_supplier`  (
  `shop_supplier_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '供应商姓名',
  `real_name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '真实姓名',
  `link_name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '联系人',
  `link_phone` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '联系电话',
  `logo_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT 'logo',
  `address` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '联系地址',
  `business_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '营业执照',
  `description` text CHARACTER SET utf8 COLLATE utf8_general_ci NULL COMMENT '商家介绍',
  `open_service` tinyint(4) NULL DEFAULT 0 COMMENT '在线客服开关0，不开启1，开启',
  `total_money` decimal(10, 2) NULL DEFAULT 0.00 COMMENT '总货款',
  `money` decimal(10, 2) NULL DEFAULT 0.00 COMMENT '当前可提现金额',
  `freeze_money` decimal(10, 2) NULL DEFAULT 0.00 COMMENT '已冻结金额',
  `cash_money` decimal(10, 2) NULL DEFAULT 0.00 COMMENT '累积提现佣金',
  `deposit_money` decimal(10, 2) NULL DEFAULT 0.00 COMMENT '保证金',
  `is_delete` tinyint(4) NULL DEFAULT 0 COMMENT '是否删除0，否1是',
  `user_id` int(11) NOT NULL COMMENT '会员id',
  `category_id` int(11) NOT NULL COMMENT '主营分类id',
  `score` varchar(20) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '5.0' COMMENT '评分',
  `express_score` decimal(2, 1) NOT NULL DEFAULT 5.0 COMMENT '物流评分',
  `server_score` decimal(2, 1) NULL DEFAULT 5.0 COMMENT '服务评分',
  `describe_score` decimal(2, 1) NULL DEFAULT 5.0 COMMENT '描述评分',
  `is_full` tinyint(4) NULL DEFAULT 0 COMMENT '资料是否齐全',
  `fav_count` int(11) NULL DEFAULT 0 COMMENT '关注人数',
  `status` tinyint(4) NOT NULL DEFAULT 0 COMMENT '店铺状态0正常10退押金中20未交保证金',
  `store_type` tinyint(4) NOT NULL DEFAULT 10 COMMENT '店铺类型10普通20自营',
  `total_gift` int(11) NULL DEFAULT 0 COMMENT '收到的礼物币总数',
  `gift_money` int(11) NULL DEFAULT 0 COMMENT '账户礼物币',
  `product_sales` int(11) NULL DEFAULT 0 COMMENT '商品总销量',
  `is_recycle` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否回收0否1是',
  `back_image` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '背景图',
  `logistics_type` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '10,20' COMMENT '配送方式',
  `commission_rate` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '平台抽成',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(11) NOT NULL COMMENT '更新时间',
  PRIMARY KEY (`shop_supplier_id`) USING BTREE,
  INDEX `name`(`name`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 2 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '供应商表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_supplier
-- ----------------------------
INSERT INTO `zmodu_supplier` VALUES (1, 'demo', '', '张三', '13800138000', 0, '湖北省武汉市汉阳区', 0, '', 0, 0.00, 0.00, 0.00, 0.00, 0.00, 0, 0, 1, '5.0', 5.0, 5.0, 5.0, 0, 0, 0, 10, 0, 0, 0, 0, '', '10,20', 0.00, 10001, 1720664405, 1720664405);

-- ----------------------------
-- Table structure for zmodu_supplier_access
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_supplier_access`;
CREATE TABLE `zmodu_supplier_access`  (
  `access_id` int(11) NOT NULL COMMENT '主键id',
  `name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '权限名称',
  `path` varchar(128) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '路由地址',
  `parent_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '父级id',
  `sort` tinyint(3) UNSIGNED NOT NULL DEFAULT 100 COMMENT '排序(数字越小越靠前)',
  `icon` varchar(128) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '菜单图标',
  `redirect_name` varchar(128) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '重定向名称',
  `is_route` tinyint(1) NOT NULL DEFAULT 0 COMMENT '是否是路由 0=不是1=是',
  `is_menu` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否是菜单 0不是 1是',
  `alias` varchar(128) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '别名(废弃)',
  `is_show` tinyint(3) UNSIGNED NOT NULL DEFAULT 1 COMMENT '是否显示1=显示0=不显示',
  `plus_category_id` int(11) NULL DEFAULT 0 COMMENT '插件分类id',
  `remark` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '描述',
  `upload_icon` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NULL DEFAULT '' COMMENT '上传菜单图标',
  `app_id` int(10) UNSIGNED NULL DEFAULT 10001 COMMENT 'app_id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`access_id`) USING BTREE,
  UNIQUE INDEX `idx_path`(`path`) USING BTREE
) ENGINE = InnoDB CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '商家用户权限表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_supplier_access
-- ----------------------------
INSERT INTO `zmodu_supplier_access` VALUES (14, '商品', '/product', 0, 0, 'icon-shangping', '/product/product/index', 1, 1, 'product', 1, 0, '', '', 10001, 1574333176, 1604564174);
INSERT INTO `zmodu_supplier_access` VALUES (15, '商品管理', '/product/product/index', 14, 0, '', '', 1, 1, 'product_index', 1, 0, '', '', 10001, 1574333221, 1604477407);
INSERT INTO `zmodu_supplier_access` VALUES (16, '添加商品', '/product/product/add', 15, 0, '', '', 1, 0, 'product_add', 1, 0, '', '', 10001, 1574333303, 1604477408);
INSERT INTO `zmodu_supplier_access` VALUES (39, '订单', '/order', 0, 1, 'icon-icon-test', '/order/order/index', 1, 1, 'order', 1, 0, '', '', 10001, 1574931867, 1604482272);
INSERT INTO `zmodu_supplier_access` VALUES (40, '订单管理', '/order/order/index', 39, 0, '', '', 1, 1, 'order_index', 1, 0, '', '', 10001, 1574932080, 1576288013);
INSERT INTO `zmodu_supplier_access` VALUES (41, '编辑商品', '/product/product/edit', 15, 1, '', '', 1, 0, 'product_edit', 1, 0, '', '', 10001, 1574938802, 1605834763);
INSERT INTO `zmodu_supplier_access` VALUES (45, '售后管理', '/order/refund/index', 39, 1, '', '', 1, 1, 'refund_refund', 1, 0, '', '', 10001, 1575342052, 1591955681);
INSERT INTO `zmodu_supplier_access` VALUES (47, '售后详情', '/order/refund/detail', 45, 2, '', '', 1, 0, 'refund_detail', 1, 0, '', '', 10001, 1575352981, 1576221706);
INSERT INTO `zmodu_supplier_access` VALUES (49, '订单详情', '/order/order/detail', 40, 1, '', '', 1, 0, 'order_detail', 1, 0, '', '', 10001, 1575353695, 1576221490);
INSERT INTO `zmodu_supplier_access` VALUES (52, '设置', '/setting', 0, 9, 'icon-icon-test1', '/setting/supplier/index', 1, 1, 'setting', 1, 0, '', '', 10001, 1575359731, 1604543380);
INSERT INTO `zmodu_supplier_access` VALUES (53, '商户信息', '/setting/supplier/index', 52, 1, '', '', 1, 1, 'setting_store', 1, 0, '', '', 10001, 1575359827, 1604543451);
INSERT INTO `zmodu_supplier_access` VALUES (58, '财务概况', '/finance/financeSituation', 57, 1, '', '', 1, 0, 'finance_financesituation', 1, 0, '', '', 10001, 1575425405, 1577087762);
INSERT INTO `zmodu_supplier_access` VALUES (61, '统计', '/statistics', 0, 8, 'icon-tongji', '/statistics/sales/index', 1, 1, 'statistics', 1, 0, '', '', 10001, 1575425980, 1605838410);
INSERT INTO `zmodu_supplier_access` VALUES (62, '销售统计', '/statistics/sales/index', 61, 1, '', '', 1, 1, 'statistics_Data', 1, 0, '', '', 10001, 1575426033, 1595317691);
INSERT INTO `zmodu_supplier_access` VALUES (63, '门店', '/store', 0, 4, 'icon-xiaochengxutubiaoguilei-', '/store/store/index', 1, 1, 'store', 1, 0, '', '', 10001, 1575426188, 1605841115);
INSERT INTO `zmodu_supplier_access` VALUES (64, '门店列表', '/store/store/index', 63, 1, '', '', 1, 1, 'store_index', 1, 0, '', '', 10001, 1575426245, 1576226029);
INSERT INTO `zmodu_supplier_access` VALUES (65, '店员列表', '/store/clerk/index', 63, 3, '', '', 1, 1, 'store_clerk_index', 1, 0, '', '', 10001, 1575426295, 1576288613);
INSERT INTO `zmodu_supplier_access` VALUES (66, '订单核销记录', '/store/order/index', 63, 2, '', '', 1, 1, 'store_order_index', 1, 0, '', '', 10001, 1575426484, 1592208037);
INSERT INTO `zmodu_supplier_access` VALUES (67, '编辑门店', '/store/store/edit', 64, 2, '', '', 1, 0, 'store_edit', 1, 0, '', '', 10001, 1575426657, 1576222576);
INSERT INTO `zmodu_supplier_access` VALUES (68, '添加门店', '/store/store/add', 64, 1, '', '', 1, 0, 'store_add', 1, 0, '', '', 10001, 1575426746, 1576222543);
INSERT INTO `zmodu_supplier_access` VALUES (69, '添加店员', '/store/clerk/add', 65, 1, '', '', 1, 0, 'clerk_add', 1, 0, '', '', 10001, 1575426942, 1576222719);
INSERT INTO `zmodu_supplier_access` VALUES (70, '编辑店员', '/store/clerk/edit', 65, 2, '', '', 1, 0, 'clerk_edit', 1, 0, '', '', 10001, 1575427016, 1576222751);
INSERT INTO `zmodu_supplier_access` VALUES (76, '运费模板', '/setting/delivery/index', 52, 3, '', '', 1, 1, 'setting_delivery_index', 1, 0, '', '', 10001, 1575427739, 1576288771);
INSERT INTO `zmodu_supplier_access` VALUES (77, '物流公司', '/setting/express/index', 52, 4, '', '', 1, 1, 'setting_express_index', 1, 0, '', '', 10001, 1575427795, 1576288405);
INSERT INTO `zmodu_supplier_access` VALUES (80, '退/发货地址', '/setting/address/index', 52, 6, '', '', 1, 1, 'setting_address_Index', 1, 0, '', '', 10001, 1575427894, 1576288429);
INSERT INTO `zmodu_supplier_access` VALUES (82, '打印机管理', '/setting/printer/index', 52, 9, '', '', 1, 1, 'setting_printer_index', 1, 0, '', '', 10001, 1575427995, 1576288447);
INSERT INTO `zmodu_supplier_access` VALUES (83, '打印设置', '/setting/printing/index', 52, 10, '', '', 1, 1, 'setting_printing', 1, 0, '', '', 10001, 1575428041, 1604556830);
INSERT INTO `zmodu_supplier_access` VALUES (89, '权限', '/auth', 0, 10, 'icon-authority', '/auth/user/index', 1, 1, 'auth', 1, 0, '', '', 10001, 1575428502, 1576288793);
INSERT INTO `zmodu_supplier_access` VALUES (90, '管理员列表', '/auth/user/index', 89, 1, '', '', 1, 1, 'auth_user_index', 1, 0, '', '', 10001, 1575428548, 1576288472);
INSERT INTO `zmodu_supplier_access` VALUES (91, '角色管理', '/auth/role/index', 89, 2, '', '', 1, 1, 'auth_role_index', 1, 0, '', '', 10001, 1575428592, 1576288479);
INSERT INTO `zmodu_supplier_access` VALUES (92, '添加管理员', '/auth/user/add', 90, 1, '', '', 1, 0, 'user_add', 1, 0, '', '', 10001, 1575428670, 1576223932);
INSERT INTO `zmodu_supplier_access` VALUES (93, '编辑管理员', '/auth/user/edit', 90, 2, '', '', 1, 0, 'user_edit', 1, 0, '', '', 10001, 1575428718, 1576223949);
INSERT INTO `zmodu_supplier_access` VALUES (94, '添加角色', '/auth/role/add', 91, 1, '', '', 1, 0, 'role_add', 1, 0, '', '', 10001, 1575428782, 1576224031);
INSERT INTO `zmodu_supplier_access` VALUES (95, '编辑角色', '/auth/role/edit', 91, 2, '', '', 1, 0, 'role_edit', 1, 0, '', '', 10001, 1575428833, 1576224010);
INSERT INTO `zmodu_supplier_access` VALUES (98, '添加优惠券', '/coupon/coupon/add', 241, 1, '', '', 1, 0, 'plus_coupon_list_add', 1, 0, '', '', 10001, 1575429999, 1606135574);
INSERT INTO `zmodu_supplier_access` VALUES (112, '编辑优惠券', '/coupon/coupon/edit', 241, 2, '', '', 1, 0, 'plus_coupon_list_edit', 1, 0, '', '', 10001, 1575454566, 1606135580);
INSERT INTO `zmodu_supplier_access` VALUES (122, '商品评价', '/product/comment/index', 14, 3, '', '', 1, 1, 'product_comment_evaluation', 1, 0, '', '', 10001, 1575852391, 1604482360);
INSERT INTO `zmodu_supplier_access` VALUES (123, '评价详情', '/product/comment/detail', 122, 1, '', '', 1, 0, 'comment_detail', 1, 0, '', '', 10001, 1575852589, 1576221135);
INSERT INTO `zmodu_supplier_access` VALUES (124, '添加运费', '/setting/delivery/add', 76, 1, '', '', 1, 0, 'delivery_add', 1, 0, '', '', 10001, 1575941834, 1576223623);
INSERT INTO `zmodu_supplier_access` VALUES (125, '编辑运费', '/setting/delivery/edit', 76, 2, '', '', 1, 0, 'delivery_edit', 1, 0, '', '', 10001, 1575941891, 1576223609);
INSERT INTO `zmodu_supplier_access` VALUES (128, '添加地址', '/setting/address/add', 80, 1, '', '', 1, 0, 'address_add', 1, 0, '', '', 10001, 1575942071, 1576223529);
INSERT INTO `zmodu_supplier_access` VALUES (129, '编辑地址', '/setting/address/edit', 80, 2, '', '', 1, 0, 'address_edit', 1, 0, '', '', 10001, 1575942113, 1576223545);
INSERT INTO `zmodu_supplier_access` VALUES (130, '添加打印机', '/setting/printer/add', 82, 1, '', '', 1, 0, 'printer_add', 1, 0, '', '', 10001, 1575942184, 1576223813);
INSERT INTO `zmodu_supplier_access` VALUES (131, '编辑打印机', '/setting/printer/edit', 82, 2, '', '', 1, 0, 'printer_edit', 1, 0, '', '', 10001, 1575942238, 1576223798);
INSERT INTO `zmodu_supplier_access` VALUES (143, '删除商品', '/product/product/delete', 15, 3, '', '', 1, 0, 'product_delete', 1, 0, '', '', NULL, 1576220720, 1576220720);
INSERT INTO `zmodu_supplier_access` VALUES (144, '一键复制', '/product/product/copy', 15, 4, '', '', 1, 0, 'product_copy', 1, 0, '', '', NULL, 1576220763, 1576220779);
INSERT INTO `zmodu_supplier_access` VALUES (154, '删除门店', '/store/store/delete', 64, 3, '', '', 1, 0, 'store_delete', 1, 0, '', '', NULL, 1576222609, 1576222609);
INSERT INTO `zmodu_supplier_access` VALUES (155, '删除店员', '/store/clerk/delete', 65, 3, '', '', 1, 0, 'clerk_delete', 1, 0, '', '', NULL, 1576222789, 1576222789);
INSERT INTO `zmodu_supplier_access` VALUES (160, '删除运费', '/setting/delivery/delete', 76, 3, '', '', 1, 0, 'delivery_delete', 1, 0, '', '', NULL, 1576223228, 1576223228);
INSERT INTO `zmodu_supplier_access` VALUES (162, '删除地址', '/setting/address/delete', 80, 3, '', '', 1, 0, 'address_delete', 1, 0, '', '', NULL, 1576223509, 1576223509);
INSERT INTO `zmodu_supplier_access` VALUES (163, '删除打印机', '/setting/printer/delete', 82, 3, '', '', 1, 0, 'printer_delete', 1, 0, '', '', NULL, 1576223776, 1576223776);
INSERT INTO `zmodu_supplier_access` VALUES (164, '删除管理员', '/auth/user/delete', 90, 3, '', '', 1, 0, 'user_delete', 1, 0, '', '', NULL, 1576223898, 1576223898);
INSERT INTO `zmodu_supplier_access` VALUES (165, '删除角色', '/auth/role/delete', 91, 3, '', '', 1, 0, 'role_delete', 1, 0, '', '', NULL, 1576223985, 1576223985);
INSERT INTO `zmodu_supplier_access` VALUES (241, '优惠券列表', '/coupon/coupon/index', 310, 1, '', '', 1, 1, '', 1, 0, '', '', 0, 1592275863, 1606135568);
INSERT INTO `zmodu_supplier_access` VALUES (242, '领取记录', '/coupon/coupon/receive', 310, 1, '', '', 1, 0, '', 1, 0, '', '', 0, 1592275974, 1606135588);
INSERT INTO `zmodu_supplier_access` VALUES (247, '客服设置', '/setting/service/index', 308, 8, '', '', 1, 1, '', 1, 0, '', '', 0, 1594344417, 1606138318);
INSERT INTO `zmodu_supplier_access` VALUES (251, '访问统计', '/statistics/user/index', 61, 1, '', '', 1, 1, '', 1, 0, '', '', 0, 1595313049, 1605839796);
INSERT INTO `zmodu_supplier_access` VALUES (252, '登录日志', '/auth/loginlog/index', 89, 10, '', '', 1, 1, '', 1, 0, '', '', 0, 0, 0);
INSERT INTO `zmodu_supplier_access` VALUES (253, '操作日志', '/auth/optlog/index', 89, 10, '', '', 1, 1, '', 1, 0, '', '', 0, 0, 0);
INSERT INTO `zmodu_supplier_access` VALUES (255, '订单发货', '/order/order/delivery', 40, 1, '', '', 0, 0, '', 1, 0, '', '', 0, 1598685493, 1598685697);
INSERT INTO `zmodu_supplier_access` VALUES (256, '订单改价', '/order/order/updatePrice', 40, 1, '', '', 0, 0, '', 1, 0, '', '', NULL, 1598753520, 1598753520);
INSERT INTO `zmodu_supplier_access` VALUES (257, '取消审核', '/order/operate/confirmCancel', 40, 1, '', '', 0, 0, '', 1, 0, '', '', NULL, 1598753587, 1598753587);
INSERT INTO `zmodu_supplier_access` VALUES (258, '订单核销', '/order/operate/extract', 40, 1, '', '', 0, 0, '', 1, 0, '', '', NULL, 1598753609, 1598753609);
INSERT INTO `zmodu_supplier_access` VALUES (259, '满额包邮', '/setting/fullfree/index', 308, 9, '', '', 1, 1, 'plus_fullfree_index', 1, 1, '满额包邮', '', 0, 1598793650, 1606138293);
INSERT INTO `zmodu_supplier_access` VALUES (260, '满减活动', '/setting/fullreduce/index', 308, 9, '', '', 1, 1, 'plus_fullfree_index', 1, 1, '', '', 0, 1599390970, 1606138303);
INSERT INTO `zmodu_supplier_access` VALUES (261, '满减添加', '/setting/fullreduce/add', 260, 1, '', '', 1, 0, '', 1, 0, '', '', 0, 1599394988, 1604556851);
INSERT INTO `zmodu_supplier_access` VALUES (262, '满减修改', '/setting/fullreduce/edit', 260, 1, '', '', 1, 0, '', 1, 0, '', '', 0, 1599395000, 1604556862);
INSERT INTO `zmodu_supplier_access` VALUES (272, '财务', '/cash', 0, 7, 'icon-caiwu', '/cash/cash/index', 1, 1, '', 1, 0, '', '', 0, 1604568543, 1606136364);
INSERT INTO `zmodu_supplier_access` VALUES (273, '财务概况', '/cash/cash/index', 272, 1, '', '', 1, 1, '', 1, 0, '', '', 0, 1604568630, 1606136129);
INSERT INTO `zmodu_supplier_access` VALUES (274, '提现记录', '/cash/cash/lists', 272, 2, '', '', 1, 1, '', 1, 0, '', '', 0, 1604568659, 1606136469);
INSERT INTO `zmodu_supplier_access` VALUES (276, '提现设置', '/cash/cash/account', 272, 4, '', '', 1, 1, '', 1, 0, '', '', 0, 1604569004, 1606184108);
INSERT INTO `zmodu_supplier_access` VALUES (279, 'banner列表', '/operate/ad/index', 308, 1, '', '', 1, 1, '', 1, 0, '', '', 0, 1604570988, 1606189211);
INSERT INTO `zmodu_supplier_access` VALUES (280, '添加banner', '/operate/ad/add', 279, 1, '', '', 1, 0, '', 1, 0, '', '', 0, 1604571011, 1606189220);
INSERT INTO `zmodu_supplier_access` VALUES (281, '编辑banner', '/operate/ad/edit', 279, 1, '', '', 1, 0, '', 1, 0, '', '', 0, 1604571031, 1606189228);
INSERT INTO `zmodu_supplier_access` VALUES (282, '删除banner', '/operate/ad/delete', 279, 1, '', '', 1, 0, '', 1, 0, '', '', 0, 1604571052, 1606189238);
INSERT INTO `zmodu_supplier_access` VALUES (287, '活动', '/activity', 0, 2, 'icon-huodong', '/activity/seckill/index', 1, 1, 'auth', 1, 0, '', '', 0, 1604892294, 1605841140);
INSERT INTO `zmodu_supplier_access` VALUES (288, '限时秒杀', '/activity/seckill/index', 287, 1, '', '', 1, 1, '', 1, 0, '', '', 0, 1604892766, 1604900462);
INSERT INTO `zmodu_supplier_access` VALUES (289, '限时拼团', '/activity/assemble/index', 287, 1, '', '', 1, 1, '', 1, 0, '', '', 0, 1604892984, 1604900479);
INSERT INTO `zmodu_supplier_access` VALUES (290, '限时砍价', '/activity/bargain/index', 287, 1, '', '', 1, 1, '', 1, 0, '', '', 0, 1604893008, 1604993275);
INSERT INTO `zmodu_supplier_access` VALUES (291, '积分商城', '/activity/point/index', 287, 1, '', '', 1, 1, '', 1, 0, '', '', 0, 1604900450, 1604996181);
INSERT INTO `zmodu_supplier_access` VALUES (292, '秒杀活动', '/activity/seckill/list', 288, 1, '', '', 1, 0, '', 1, 0, '', '', 0, 1604909733, 1605099907);
INSERT INTO `zmodu_supplier_access` VALUES (293, '秒杀商品', '/activity/seckill/my', 288, 1, '', '', 1, 0, '', 1, 0, '', '', 0, 1604909749, 1605099914);
INSERT INTO `zmodu_supplier_access` VALUES (294, '活动报名', '/activity/seckill/add', 292, 1, '', '', 1, 0, '', 1, 0, '', '', 0, 1604914178, 1605099920);
INSERT INTO `zmodu_supplier_access` VALUES (295, '修改', '/activity/seckill/edit', 293, 1, '', '', 1, 0, '', 1, 0, '', '', 0, 1604914197, 1605099925);
INSERT INTO `zmodu_supplier_access` VALUES (296, '拼团商品', '/activity/assemble/list', 289, 1, '', '', 1, 0, '', 1, 0, '', '', 0, 1604976543, 1605099935);
INSERT INTO `zmodu_supplier_access` VALUES (297, '拼团列表', '/activity/assemble/record', 289, 1, '', '', 1, 0, '', 1, 0, '', '', 0, 1604976870, 1605099939);
INSERT INTO `zmodu_supplier_access` VALUES (298, '添加商品', '/activity/assemble/add', 296, 1, '', '', 1, 0, '', 1, 0, '', '', 0, 1604976890, 1605099944);
INSERT INTO `zmodu_supplier_access` VALUES (299, '编辑商品', '/activity/assemble/edit', 296, 1, '', '', 1, 0, '', 1, 0, '', '', 0, 1604976909, 1605099949);
INSERT INTO `zmodu_supplier_access` VALUES (300, '砍价商品', '/activity/bargain/list', 290, 1, '', '', 1, 0, '', 1, 0, '', '', 0, 1604988816, 1606130321);
INSERT INTO `zmodu_supplier_access` VALUES (301, '砍价列表', '/activity/bargain/record', 290, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1604988859, 1604988859);
INSERT INTO `zmodu_supplier_access` VALUES (302, '添加商品', '/activity/bargain/add', 300, 1, '', '', 1, 0, '', 1, 0, '', '', 0, 1604988883, 1604992581);
INSERT INTO `zmodu_supplier_access` VALUES (303, '编辑商品', '/activity/bargain/edit', 300, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1604988899, 1604988899);
INSERT INTO `zmodu_supplier_access` VALUES (305, '添加商品', '/activity/point/add', 291, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1604994497, 1604994497);
INSERT INTO `zmodu_supplier_access` VALUES (306, '编辑商品', '/activity/point/edit', 291, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1604994510, 1604994510);
INSERT INTO `zmodu_supplier_access` VALUES (307, '分销订单', '/order/agent/index', 39, 1, '', '', 1, 1, '', 1, 0, '', '', 0, 1605680060, 1605680461);
INSERT INTO `zmodu_supplier_access` VALUES (308, '运营', '/operate', 0, 6, 'icon-yunyingguanli', '/operate/ad/index', 1, 1, '', 1, 0, '', '', 0, 1605833693, 1605836030);
INSERT INTO `zmodu_supplier_access` VALUES (310, '优惠券', '/coupon', 308, 1, '', '/coupon/coupon/index', 1, 1, '', 1, 0, '', '', 0, 1605833744, 1606135538);
INSERT INTO `zmodu_supplier_access` VALUES (311, '商户结算', '/cash/settled/index', 272, 1, '', '', 1, 1, '', 1, 0, '', '', NULL, 1605843130, 1605843130);
INSERT INTO `zmodu_supplier_access` VALUES (312, '粉丝', '/operate/fans/index', 308, 1, '', '', 1, 1, '', 1, 0, '', '', 0, 1606101074, 1606101885);
INSERT INTO `zmodu_supplier_access` VALUES (315, '满减删除', '/setting/fullreduce/delete', 260, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1606138673, 1606138673);
INSERT INTO `zmodu_supplier_access` VALUES (1606287957, '结算详情', '/cash/settled/detail', 311, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1606287957, 1606287957);
INSERT INTO `zmodu_supplier_access` VALUES (1606558637, '服务保障', '/shop/security/index', 308, 10, '', '', 1, 1, '', 1, 0, '', '', 0, 1606558637, 1606558681);
INSERT INTO `zmodu_supplier_access` VALUES (1607572104, '直播', '/live', 0, 3, 'icon-zhibo', '/live/index', 1, 1, '', 1, 0, '', '', 0, 1607572104, 1607586662);
INSERT INTO `zmodu_supplier_access` VALUES (1607586188, '房间管理', '/live/room/index', 1607586592, 1, '', '', 1, 0, '', 1, 0, '', '', 0, 1607586188, 1607586629);
INSERT INTO `zmodu_supplier_access` VALUES (1607586216, '房间修改', '/live/room/edit', 1607586188, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1607586216, 1607586216);
INSERT INTO `zmodu_supplier_access` VALUES (1607586246, '房间产品', '/live/room/product', 1607586188, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1607586246, 1607586246);
INSERT INTO `zmodu_supplier_access` VALUES (1607586288, '礼物排行', '/live/room/user_gift', 1607586188, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1607586288, 1607586288);
INSERT INTO `zmodu_supplier_access` VALUES (1607586383, '直播订单', '/live/room/getOrderList', 1607586592, 1, '', '', 1, 0, '', 1, 0, '', '', 0, 1607586383, 1607586619);
INSERT INTO `zmodu_supplier_access` VALUES (1607586592, '直播管理', '/live/index', 1607572104, 1, '', '', 1, 1, '', 1, 0, '', '', NULL, 1607586592, 1607586592);
INSERT INTO `zmodu_supplier_access` VALUES (1609140208, '客服', '/chat', 0, 5, 'icon-kefu', '/chat/chat/index', 1, 1, 'store', 1, 0, '', '', 0, 1609140208, 1609999185);
INSERT INTO `zmodu_supplier_access` VALUES (1609140429, '聊天记录', '/chat/chat/list', 1609591294, 2, '', '', 1, 1, '', 1, 0, '', '', 0, 1609140429, 1609913372);
INSERT INTO `zmodu_supplier_access` VALUES (1609144870, '对话记录', '/chat/chat/record', 1609140429, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1609144870, 1609144870);
INSERT INTO `zmodu_supplier_access` VALUES (1609591294, '客服列表', '/chat/chat/index', 1609140208, 1, '', '', 1, 1, '', 1, 0, '', '', NULL, 1609591294, 1609591294);
INSERT INTO `zmodu_supplier_access` VALUES (1615017509, '订单物流', '/order/order/express', 40, 1, '', '', 0, 0, '', 1, 0, '', '', NULL, 1615017509, 1615017509);
INSERT INTO `zmodu_supplier_access` VALUES (1615017525, '订单改地址', '/order/order/updateAddress', 40, 1, '', '', 0, 0, '', 1, 0, '', '', NULL, 1615017525, 1615017525);
INSERT INTO `zmodu_supplier_access` VALUES (1616228260, '批量发货', '/order/operate/batchDelivery', 40, 10, '', '', 0, 0, '', 1, 0, '', '', NULL, 1616228260, 1616228260);
INSERT INTO `zmodu_supplier_access` VALUES (1616228316, '订单导出', '/order/operate/export', 40, 9, '', '', 0, 0, '', 1, 0, '', '', NULL, 1616228316, 1616228316);
INSERT INTO `zmodu_supplier_access` VALUES (1646982814, '商品满减', '/operate/fullreduce/product', 308, 10, '', '', 1, 1, '', 1, 0, '', '', 0, 1646982814, 1646983233);
INSERT INTO `zmodu_supplier_access` VALUES (1654770940, '预售活动', '/activity/advance/index', 287, 1, '', '', 1, 1, '', 1, 0, '', '', 0, 1654770940, 1654770948);
INSERT INTO `zmodu_supplier_access` VALUES (1654770974, '添加', '/activity/advance/add', 1654770940, 1, '', '', 1, 0, '', 1, 0, '', '', 0, 1654770974, 1654771071);
INSERT INTO `zmodu_supplier_access` VALUES (1654771087, '编辑', '/activity/advance/edit', 1654770940, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1654771087, 1654771087);
INSERT INTO `zmodu_supplier_access` VALUES (1654771098, '删除', '/activity/advance/delete', 1654770940, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1654771098, 1654771098);
INSERT INTO `zmodu_supplier_access` VALUES (1656406056, '商品上下架', '/product/product/state', 15, 4, '', '', 1, 0, 'product_copy', 1, 0, '', '', NULL, 1656406056, 1656406056);
INSERT INTO `zmodu_supplier_access` VALUES (1656406082, '评价审核', '/product/comment/edit', 122, 1, '', '', 1, 0, 'comment_detail', 1, 0, '', '', NULL, 1656406082, 1656406082);
INSERT INTO `zmodu_supplier_access` VALUES (1656406395, '取消订单', '/order/order/orderCancel', 40, 10, '', '', 0, 0, '', 1, 0, '', '', NULL, 1656406395, 1656406395);
INSERT INTO `zmodu_supplier_access` VALUES (1656406835, '售后审核', '/order/refund/audit', 45, 2, '', '', 1, 0, 'refund_detail', 1, 0, '', '', NULL, 1656406835, 1656406835);
INSERT INTO `zmodu_supplier_access` VALUES (1656406917, '优惠券详情', '/coupon/coupon/couponDetail', 241, 2, '', '', 1, 0, 'plus_coupon_list_edit', 1, 0, '', '', NULL, 1656406917, 1656406917);
INSERT INTO `zmodu_supplier_access` VALUES (1656406938, '删除优惠券', '/coupon/coupon/delete', 241, 2, '', '', 1, 0, 'plus_coupon_list_edit', 1, 0, '', '', NULL, 1656406938, 1656406938);
INSERT INTO `zmodu_supplier_access` VALUES (1656407016, '申请服务', '/shop/security/apply', 1606558637, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656407016, 1656407016);
INSERT INTO `zmodu_supplier_access` VALUES (1656407041, '退出服务', '/shop/security/quit', 1606558637, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656407041, 1656407041);
INSERT INTO `zmodu_supplier_access` VALUES (1656407090, '设置', '/operate/fullreduce/editProduct', 1646982814, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656407090, 1656407090);
INSERT INTO `zmodu_supplier_access` VALUES (1656407156, '提现', '/cash/cash/apply', 273, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656407156, 1656407156);
INSERT INTO `zmodu_supplier_access` VALUES (1656407192, '退保证金', '/supplier/supplier/refund', 273, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656407192, 1656407192);
INSERT INTO `zmodu_supplier_access` VALUES (1656408255, '删除', '/activity/seckill/del', 293, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656408255, 1656408255);
INSERT INTO `zmodu_supplier_access` VALUES (1656408336, '删除商品', '/activity/assemble/del', 296, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656408336, 1656408336);
INSERT INTO `zmodu_supplier_access` VALUES (1656408371, '删除商品', '/activity/bargain/del', 300, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656408371, 1656408371);
INSERT INTO `zmodu_supplier_access` VALUES (1656408402, '删除商品', '/activity/point/del', 291, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1656408402, 1656408402);
INSERT INTO `zmodu_supplier_access` VALUES (1692096159, '微信小程序发货', '/order/order/wxDelivery', 40, 10, '', '', 0, 0, '', 1, 0, '', '', NULL, 1692096159, 1692096159);
INSERT INTO `zmodu_supplier_access` VALUES (1699001167, '分销商品', '/activity/agent/product', 287, 1, '', '', 1, 1, '', 1, 0, '', '', NULL, 1699001167, 1699001167);
INSERT INTO `zmodu_supplier_access` VALUES (1699001221, '设置', '/activity/agent/edit', 1699001167, 1, '', '', 0, 0, '', 1, 0, '', '', NULL, 1699001221, 1699001268);
INSERT INTO `zmodu_supplier_access` VALUES (1699001262, '参与设置', '/activity/agent/setAgent', 1699001167, 1, '', '', 0, 0, '', 1, 0, '', '', NULL, 1699001262, 1699001272);
INSERT INTO `zmodu_supplier_access` VALUES (1699318794, '添加', '/chat/chat/add', 1609591294, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1699318794, 1699318805);
INSERT INTO `zmodu_supplier_access` VALUES (1699318817, '编辑', '/chat/chat/edit', 1609591294, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1699318817, 1699318817);
INSERT INTO `zmodu_supplier_access` VALUES (1699318831, '删除', '/chat/chat/delete', 1609591294, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1699318831, 1699318831);
INSERT INTO `zmodu_supplier_access` VALUES (1699318850, '状态设置', '/chat/chat/set', 1609591294, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1699318850, 1699318850);
INSERT INTO `zmodu_supplier_access` VALUES (1705287762, '面单模板', '/setting/template/index', 52, 4, '', '', 1, 1, 'setting_express_index', 1, 0, '', '', NULL, 1705287762, 1705287762);
INSERT INTO `zmodu_supplier_access` VALUES (1705287927, '面单配置', '/setting/label/index', 52, 4, '', '', 1, 1, 'setting_express_index', 1, 0, '', '', NULL, 1705287927, 1705287927);
INSERT INTO `zmodu_supplier_access` VALUES (1705288245, '添加', '/setting/label/add', 1705287927, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1705288245, 1705288245);
INSERT INTO `zmodu_supplier_access` VALUES (1705288255, '编辑', '/setting/label/edit', 1705287927, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1705288255, 1705288255);
INSERT INTO `zmodu_supplier_access` VALUES (1705288265, '删除', '/setting/label/delete', 1705287927, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1705288265, 1705288265);
INSERT INTO `zmodu_supplier_access` VALUES (1705302202, '取消电子面单', '/order/order/labelCancel', 40, 10, '', '', 0, 0, '', 1, 0, '', '', NULL, 1705302202, 1705302202);
INSERT INTO `zmodu_supplier_access` VALUES (1705302231, '电子面单复打', '/order/order/printRepeate', 40, 10, '', '', 0, 0, '', 1, 0, '', '', NULL, 1705302231, 1705302231);
INSERT INTO `zmodu_supplier_access` VALUES (1741405656, '虚拟商品发货', '/order/order/virtual', 40, 10, '', '', 0, 0, '', 1, 0, '', '', NULL, 1741405656, 1741405656);
INSERT INTO `zmodu_supplier_access` VALUES (1741418735, '买送活动', '/activity/buyactivity/index', 287, 1, '', '', 1, 1, '', 1, 0, '', '', NULL, 1741418735, 1741418735);
INSERT INTO `zmodu_supplier_access` VALUES (1741418756, '添加', '/activity/buyactivity/add', 1741418735, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1741418756, 1741420434);
INSERT INTO `zmodu_supplier_access` VALUES (1741418769, '编辑', '/activity/buyactivity/edit', 1741418735, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1741418769, 1741420438);
INSERT INTO `zmodu_supplier_access` VALUES (1741418781, '删除', '/activity/buyactivity/delete', 1741418735, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1741418781, 1741420442);
INSERT INTO `zmodu_supplier_access` VALUES (1741422461, '状态', '/activity/buyactivity/state', 1741418735, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1741422461, 1741422461);
INSERT INTO `zmodu_supplier_access` VALUES (1752892217, '统计', '/activity/seckill/statistics', 293, 2, '', '', 1, 0, '', 1, 0, '', '', NULL, 1752892217, 1752893416);
INSERT INTO `zmodu_supplier_access` VALUES (1752892249, '参与人', '/activity/seckill/join', 1752892217, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1752892249, 1752892249);
INSERT INTO `zmodu_supplier_access` VALUES (1752892266, '活动订单', '/activity/seckill/order', 1752892217, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1752892266, 1752892266);
INSERT INTO `zmodu_supplier_access` VALUES (1752893404, '商品上下架', '/activity/seckill/state', 293, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1752893404, 1752893404);
INSERT INTO `zmodu_supplier_access` VALUES (1757903498, '导入卡密', '/product/product/importVirtual', 15, 6, '', '', 0, 0, 'product_copy', 1, 0, '', '', NULL, 1757903498, 1757903508);
INSERT INTO `zmodu_supplier_access` VALUES (1757903540, '卡密管理', '/product/virtual/index', 15, 6, '', '', 0, 0, 'product_copy', 1, 0, '', '', NULL, 1757903540, 1757903540);
INSERT INTO `zmodu_supplier_access` VALUES (1757903561, '添加', '/product/virtual/add', 1757903540, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1757903561, 1757903561);
INSERT INTO `zmodu_supplier_access` VALUES (1757903580, '编辑', '/product/virtual/edit', 1757903540, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1757903580, 1757903580);
INSERT INTO `zmodu_supplier_access` VALUES (1757903597, '删除', '/product/virtual/delete', 1757903540, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1757903597, 1757903597);
INSERT INTO `zmodu_supplier_access` VALUES (1757903618, '查看订单', '/product/virtual/order', 1757903540, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1757903618, 1757903618);
INSERT INTO `zmodu_supplier_access` VALUES (1761380726, '统计', '/activity/assemble/statistics', 296, 2, '', '', 1, 0, '', 1, 0, '', '', NULL, 1761380726, 1761889972);
INSERT INTO `zmodu_supplier_access` VALUES (1761380762, '参与人', '/activity/assemble/join', 1761380726, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1761380762, 1761380762);
INSERT INTO `zmodu_supplier_access` VALUES (1761380786, '详情', '/activity/assemble/detail', 1761380762, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1761380786, 1761380786);
INSERT INTO `zmodu_supplier_access` VALUES (1761380800, '活动订单', '/activity/assemble/order', 1761380726, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1761380800, 1761380800);
INSERT INTO `zmodu_supplier_access` VALUES (1761889958, '商品状态', '/activity/assemble/state', 296, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1761889958, 1761889958);
INSERT INTO `zmodu_supplier_access` VALUES (1761892211, '详情', '/activity/assemble/recordDetail', 297, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1761892211, 1761892211);
INSERT INTO `zmodu_supplier_access` VALUES (1761894510, '商品状态', '/activity/bargain/state', 300, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1761894510, 1761894510);
INSERT INTO `zmodu_supplier_access` VALUES (1761894559, '详情', '/activity/bargain/recordDetail', 301, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1761894559, 1761894559);
INSERT INTO `zmodu_supplier_access` VALUES (1761894590, '统计', '/activity/bargain/statistics', 300, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1761894590, 1761894590);
INSERT INTO `zmodu_supplier_access` VALUES (1761894616, '参与人', '/activity/bargain/join', 1761894590, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1761894616, 1761894616);
INSERT INTO `zmodu_supplier_access` VALUES (1761894650, '详情', '/activity/bargain/detail', 1761894616, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1761894650, 1761894650);
INSERT INTO `zmodu_supplier_access` VALUES (1761894669, '活动订单', '/activity/bargain/order', 1761894590, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1761894669, 1761894669);
INSERT INTO `zmodu_supplier_access` VALUES (1762220032, '立即成团', '/activity/assemble/finish', 297, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1762220032, 1762220032);
INSERT INTO `zmodu_supplier_access` VALUES (1763089788, '撤销', '/store/order/cancel', 66, 1, '', '', 1, 0, '', 1, 0, '', '', NULL, 1763089788, 1763089788);

-- ----------------------------
-- Table structure for zmodu_supplier_account
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_supplier_account`;
CREATE TABLE `zmodu_supplier_account`  (
  `account_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `shop_supplier_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '供应商id',
  `alipay_name` varchar(30) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '支付宝姓名',
  `alipay_account` varchar(30) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '支付宝账号',
  `bank_name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '开户行名称',
  `bank_account` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '银行开户名',
  `bank_card` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '银行卡号',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(11) NOT NULL COMMENT '更新时间',
  PRIMARY KEY (`account_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '供应商提现账号表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_supplier_account
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_supplier_apply
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_supplier_apply`;
CREATE TABLE `zmodu_supplier_apply`  (
  `supplier_apply_id` int(11) NOT NULL AUTO_INCREMENT COMMENT 'id',
  `user_name` varchar(30) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL COMMENT '姓名',
  `password` varchar(50) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NULL DEFAULT '' COMMENT '密码',
  `store_name` varchar(50) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL COMMENT '店铺名称',
  `mobile` varchar(30) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL COMMENT '手机号码',
  `business_id` int(11) NOT NULL DEFAULT 0 COMMENT '营业执照',
  `status` tinyint(1) NOT NULL DEFAULT 0 COMMENT '0待审核1审核通过2未通过',
  `user_id` int(11) NULL DEFAULT 0 COMMENT '会员id',
  `category_id` int(11) NOT NULL COMMENT '主营分类id',
  `deposit_money` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '保证金',
  `shop_supplier_id` int(11) NOT NULL DEFAULT 0 COMMENT '商户id',
  `is_delete` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '0=显示1=伪删除',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(11) NOT NULL COMMENT '更新时间',
  `content` varchar(120) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NULL DEFAULT NULL COMMENT '审核备注',
  PRIMARY KEY (`supplier_apply_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8mb4 COLLATE = utf8mb4_general_ci COMMENT = '商户申请表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_supplier_apply
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_supplier_capital
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_supplier_capital`;
CREATE TABLE `zmodu_supplier_capital`  (
  `id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `shop_supplier_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '分销商用户id',
  `flow_type` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '资金流动类型 (10订单收入 20提现支出)',
  `money` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '金额',
  `describe` varchar(500) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '描述',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '供应商资金明细表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_supplier_capital
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_supplier_cash
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_supplier_cash`;
CREATE TABLE `zmodu_supplier_cash`  (
  `id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `shop_supplier_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '供应商用户id',
  `money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '提现金额',
  `pay_type` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '打款方式 (10支付宝 20银行卡)',
  `apply_status` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '申请状态 (10待审核 20审核通过 30驳回 40已打款)',
  `audit_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '审核时间',
  `reject_reason` varchar(500) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '驳回原因',
  `real_money` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '实际到账金额',
  `cash_ratio` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '提现比例',
  `cash_money` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '手续费',
  `out_biz_no` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '支付宝转账商户订单号',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '供应商提现明细表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_supplier_cash
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_supplier_category
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_supplier_category`;
CREATE TABLE `zmodu_supplier_category`  (
  `category_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '类型id',
  `name` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '分类名称',
  `deposit_money` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '保证金',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`category_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 3 CHARACTER SET = utf8mb4 COLLATE = utf8mb4_general_ci COMMENT = 'banner类型' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_supplier_category
-- ----------------------------
INSERT INTO `zmodu_supplier_category` VALUES (1, '电器', 0.00, 10001, 1720663925, 1720663925);
INSERT INTO `zmodu_supplier_category` VALUES (2, '食品', 0.00, 10001, 1720664066, 1720664066);

-- ----------------------------
-- Table structure for zmodu_supplier_deposit_order
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_supplier_deposit_order`;
CREATE TABLE `zmodu_supplier_deposit_order`  (
  `order_id` int(11) NOT NULL AUTO_INCREMENT COMMENT '订单id',
  `order_no` varchar(20) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL COMMENT '订单号',
  `user_id` int(11) NOT NULL COMMENT '会员id',
  `pay_price` decimal(10, 2) NOT NULL COMMENT '金额',
  `pay_status` tinyint(4) NOT NULL DEFAULT 10 COMMENT '支付状态(10待支付 20已支付)',
  `pay_time` int(11) NOT NULL DEFAULT 0 COMMENT '付款时间',
  `transaction_id` varchar(30) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL DEFAULT '' COMMENT '微信支付交易号',
  `pay_type` tinyint(4) NOT NULL DEFAULT 20 COMMENT '支付方式(10余额支付 20微信支付 30支付宝 40积分支付)',
  `app_id` int(11) NOT NULL COMMENT '小程序商城id',
  `pay_source` varchar(50) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL DEFAULT '' COMMENT '支付来源,wx,android,ios',
  `balance` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '余额抵扣金额',
  `online_money` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '在线支付金额',
  `shop_supplier_id` int(11) NOT NULL DEFAULT 0 COMMENT '商户id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(11) NOT NULL COMMENT '更新时间',
  PRIMARY KEY (`order_id`) USING BTREE,
  UNIQUE INDEX `order_no`(`order_no`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8mb4 COLLATE = utf8mb4_general_ci COMMENT = '入住押金订单' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_supplier_deposit_order
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_supplier_deposit_refund
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_supplier_deposit_refund`;
CREATE TABLE `zmodu_supplier_deposit_refund`  (
  `deposit_refund_id` int(11) NOT NULL AUTO_INCREMENT COMMENT 'id',
  `shop_supplier_id` int(11) NOT NULL,
  `deposit_money` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '押金',
  `status` tinyint(4) NOT NULL DEFAULT 0 COMMENT '0待审核1通过2拒绝',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '程序id',
  `audit_time` int(11) NULL DEFAULT 0 COMMENT '审核时间',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(11) NOT NULL COMMENT '更新时间',
  PRIMARY KEY (`deposit_refund_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8mb4 COLLATE = utf8mb4_general_ci COMMENT = '退押金申请表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_supplier_deposit_refund
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_supplier_login_log
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_supplier_login_log`;
CREATE TABLE `zmodu_supplier_login_log`  (
  `login_log_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `shop_supplier_id` int(11) NULL DEFAULT 0 COMMENT '供应商id',
  `username` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '用户名',
  `ip` varchar(128) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '登录ip',
  `result` varchar(128) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '登录结果',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '签到时间',
  PRIMARY KEY (`login_log_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '管理员登录记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_supplier_login_log
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_supplier_opt_log
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_supplier_opt_log`;
CREATE TABLE `zmodu_supplier_opt_log`  (
  `opt_log_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `supplier_user_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '用户id',
  `title` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '标题',
  `url` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '访问url',
  `request_type` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '请求类型',
  `browser` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '浏览器',
  `agent` varchar(500) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '浏览器信息',
  `content` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NULL COMMENT '操作内容',
  `shop_supplier_id` int(11) NOT NULL DEFAULT 0 COMMENT '商户id',
  `ip` varchar(128) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '登录ip',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '签到时间',
  PRIMARY KEY (`opt_log_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '管理员操作记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_supplier_opt_log
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_supplier_role
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_supplier_role`;
CREATE TABLE `zmodu_supplier_role`  (
  `role_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '角色id',
  `role_name` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '角色名称',
  `sort` int(10) UNSIGNED NOT NULL DEFAULT 100 COMMENT '排序(数字越小越靠前)',
  `shop_supplier_id` int(11) NOT NULL DEFAULT 0 COMMENT '商户id',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`role_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '商家用户角色表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_supplier_role
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_supplier_role_access
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_supplier_role_access`;
CREATE TABLE `zmodu_supplier_role_access`  (
  `id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `role_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '角色id',
  `access_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '权限id',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  PRIMARY KEY (`id`) USING BTREE,
  INDEX `role_id`(`role_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '商家用户角色权限关系表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_supplier_role_access
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_supplier_service
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_supplier_service`;
CREATE TABLE `zmodu_supplier_service`  (
  `service_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `shop_supplier_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '供应商用户id',
  `service_type` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '资金流动类型 (10微信，qq等 20在线客户)',
  `wechat` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '微信号',
  `qq` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT 'qq',
  `phone` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '客服电话',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`service_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '供应商客服表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_supplier_service
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_supplier_service_apply
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_supplier_service_apply`;
CREATE TABLE `zmodu_supplier_service_apply`  (
  `service_apply_id` int(11) NOT NULL AUTO_INCREMENT COMMENT 'ID',
  `shop_supplier_id` int(11) NOT NULL COMMENT '供应商id',
  `service_security_id` int(11) NOT NULL COMMENT '服务id',
  `status` tinyint(1) NOT NULL DEFAULT 0 COMMENT '0待审核1通过2拒绝',
  `content` varchar(150) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT NULL COMMENT '备注',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(11) NOT NULL COMMENT '更新时间',
  PRIMARY KEY (`service_apply_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '服务保障申请' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_supplier_service_apply
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_supplier_service_security
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_supplier_service_security`;
CREATE TABLE `zmodu_supplier_service_security`  (
  `service_security_id` int(11) NOT NULL AUTO_INCREMENT COMMENT 'ID',
  `name` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL COMMENT '名称',
  `describe` varchar(100) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL COMMENT '描述',
  `logo` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT 'logo',
  `status` tinyint(1) NOT NULL DEFAULT 1 COMMENT '状态1开启0关闭',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(11) NOT NULL COMMENT '更新时间',
  PRIMARY KEY (`service_security_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 8 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '供应商服务保障' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_supplier_service_security
-- ----------------------------
INSERT INTO `zmodu_supplier_service_security` VALUES (1, '7天退换', '7天无理由退货', 'http://qn-cdn.jjjshop.net/202012081403350e08c7839.png', 1, 10001, 1600091854, 1607649450);
INSERT INTO `zmodu_supplier_service_security` VALUES (2, '正品保障', '正品保障', 'http://qn-cdn.jjjshop.net/20201208140319537d84844.png', 1, 10001, 1607396686, 1607649465);
INSERT INTO `zmodu_supplier_service_security` VALUES (3, '两小时发货', '两小时发货', 'http://qn-cdn.jjjshop.net/20201208140315586b77312.png', 1, 10001, 1607396836, 1607649478);
INSERT INTO `zmodu_supplier_service_security` VALUES (4, '退货承诺', '退货承诺', 'http://qn-cdn.jjjshop.net/202012081403398bdbc9019.png', 1, 10001, 1607398193, 1607649485);
INSERT INTO `zmodu_supplier_service_security` VALUES (5, '试用中心', '试用中心', 'http://qn-cdn.jjjshop.net/20201208140343368201047.png', 1, 10001, 1607398201, 1607649491);
INSERT INTO `zmodu_supplier_service_security` VALUES (6, '实体验证', '实体验证', 'http://qn-cdn.jjjshop.net/20201208140322b9cf16401.png', 1, 10001, 1607398216, 1607649500);
INSERT INTO `zmodu_supplier_service_security` VALUES (7, '消协保证', '消协保证', 'http://qn-cdn.jjjshop.net/20201208140319537d84844.png', 1, 10001, 1607398224, 1607649514);

-- ----------------------------
-- Table structure for zmodu_supplier_user
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_supplier_user`;
CREATE TABLE `zmodu_supplier_user`  (
  `supplier_user_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `user_id` int(11) NULL DEFAULT 0 COMMENT '绑定的用户id',
  `user_name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '用户名',
  `password` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '登录密码',
  `real_name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '姓名',
  `is_super` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否为超级管理员0不是,1是',
  `shop_supplier_id` int(11) NOT NULL COMMENT '关联供应商id',
  `is_delete` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '0=显示1=伪删除',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(11) NOT NULL COMMENT '更新时间',
  PRIMARY KEY (`supplier_user_id`) USING BTREE,
  INDEX `user_name`(`user_name`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 2 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '商家用户记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_supplier_user
-- ----------------------------
INSERT INTO `zmodu_supplier_user` VALUES (1, 0, 'demo', '06e0213dcf92e986d383029494966903', 'demo', 1, 1, 0, 10001, 1720664405, 1720664405);

-- ----------------------------
-- Table structure for zmodu_supplier_user_role
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_supplier_user_role`;
CREATE TABLE `zmodu_supplier_user_role`  (
  `id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `supplier_user_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '超管用户id',
  `role_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '角色id',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`id`) USING BTREE,
  INDEX `admin_user_id`(`supplier_user_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '商家用户角色记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_supplier_user_role
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_table
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_table`;
CREATE TABLE `zmodu_table`  (
  `table_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '名称',
  `content` longtext CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL COMMENT 'json格式',
  `sort` tinyint(4) NULL DEFAULT 100 COMMENT '排序',
  `total_count` int(11) NULL DEFAULT 0 COMMENT '数量',
  `is_delete` tinyint(4) NULL DEFAULT 0 COMMENT '是否删除0否1是',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(11) NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`table_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '万能表单' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_table
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_table_record
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_table_record`;
CREATE TABLE `zmodu_table_record`  (
  `table_record_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `table_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '名称',
  `content` longtext CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL COMMENT 'json格式',
  `user_id` int(11) NULL DEFAULT 0 COMMENT '用户id',
  `is_delete` tinyint(4) NULL DEFAULT 0 COMMENT '是否删除0否1是',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(11) NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`table_record_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '万能表单记录' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_table_record
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_tag
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_tag`;
CREATE TABLE `zmodu_tag`  (
  `tag_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `tag_name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '标签名称',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`tag_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '用户tag表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_tag
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_upload_file
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_upload_file`;
CREATE TABLE `zmodu_upload_file`  (
  `file_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '文件id',
  `storage` varchar(20) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '存储方式',
  `group_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '文件分组id',
  `file_url` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '存储域名',
  `save_name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '保存路径',
  `file_name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '文件路径',
  `file_size` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '文件大小(字节)',
  `file_type` varchar(20) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '文件类型',
  `real_name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '文件真实名',
  `extension` varchar(20) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '文件扩展名',
  `is_user` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否为c端用户上传',
  `is_recycle` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否已回收',
  `shop_supplier_id` int(11) NULL DEFAULT 0 COMMENT '供应商id',
  `is_delete` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '软删除',
  `app_id` int(10) UNSIGNED NULL DEFAULT 0 COMMENT '应用id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`file_id`) USING BTREE,
  UNIQUE INDEX `path_idx`(`file_name`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 6 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '文件库记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_upload_file
-- ----------------------------
INSERT INTO `zmodu_upload_file` VALUES (1, 'local', 0, '', '20240711/fa16b84433fdbdb02b2482be53f416dc.jpg', '202407111043527b6d39954.jpg', 10846, 'image', '20200530092725ede950414.jpg', 'jpg', 0, 0, 0, 0, 10001, 1720665832, 0);
INSERT INTO `zmodu_upload_file` VALUES (2, 'local', 0, '', '20240711/774208f93ae744ea6fb8235cdf19e944.jpg', '20240711104352109269729.jpg', 3930, 'image', '20200530092031d9f4e0928.jpg', 'jpg', 0, 0, 0, 0, 10001, 1720665832, 0);
INSERT INTO `zmodu_upload_file` VALUES (3, 'local', 0, '', '20240711/581e387d4afcbae46f6b0664fcf951d3.jpg', '2024071110435268d275351.jpg', 114818, 'image', '1597647139312_01.jpg', 'jpg', 0, 0, 0, 0, 10001, 1720665832, 0);
INSERT INTO `zmodu_upload_file` VALUES (4, 'local', 0, '', '20240711/2971b206599ac926c6d81027d6f7f97c.jpg', '20240711104352f3a6f3285.jpg', 131169, 'image', '1597647161017_01.jpg', 'jpg', 0, 0, 0, 0, 10001, 1720665832, 0);
INSERT INTO `zmodu_upload_file` VALUES (5, 'local', 0, '', '20240711/7d764a6f1d779265af49db327be2411e.jpg', '2024071110473003fca2229.jpg', 114818, 'image', '1597647139312_01.jpg', 'jpg', 0, 0, 1, 0, 10001, 1720666050, 0);

-- ----------------------------
-- Table structure for zmodu_upload_group
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_upload_group`;
CREATE TABLE `zmodu_upload_group`  (
  `group_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '分类id',
  `group_type` varchar(10) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '文件类型',
  `group_name` varchar(30) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '分类名称',
  `sort` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '分类排序(数字越小越靠前)',
  `shop_supplier_id` int(11) NULL DEFAULT 0 COMMENT '供应商id',
  `is_delete` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否删除',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '应用id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`group_id`) USING BTREE,
  INDEX `type_index`(`group_type`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '文件库分组记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_upload_group
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_user
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_user`;
CREATE TABLE `zmodu_user`  (
  `user_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '用户id',
  `open_id` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '微信openid(唯一标示)',
  `mpopen_id` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '微信公众号openid',
  `appopen_id` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT 'openappid',
  `union_id` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '微信开放平台id',
  `app_user` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '苹果用户',
  `reg_source` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '注册来源',
  `nickName` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL DEFAULT '' COMMENT '微信昵称',
  `mobile` varchar(20) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '手机号',
  `password` varchar(120) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '密码',
  `avatarUrl` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '微信头像',
  `gender` tinyint(3) UNSIGNED NOT NULL DEFAULT 2 COMMENT '性别0=女1=男2=未知',
  `country` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '国家',
  `province` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '省份',
  `city` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '城市',
  `address_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '默认收货地址',
  `balance` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '用户可用余额',
  `points` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '用户可用积分',
  `pay_money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '用户总支付的金额',
  `expend_money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '实际消费的金额(不含退款)',
  `grade_id` int(10) UNSIGNED NOT NULL DEFAULT 1 COMMENT '会员等级id',
  `referee_id` int(11) NOT NULL DEFAULT 0 COMMENT '推荐人id',
  `total_points` decimal(10, 2) NULL DEFAULT 0.00 COMMENT '累计积分',
  `total_invite` int(11) NULL DEFAULT 0 COMMENT '总邀请人数',
  `freeze_money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '已冻结佣金',
  `cash_money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '累积提现佣金',
  `user_type` tinyint(4) NOT NULL DEFAULT 1 COMMENT '供应商状态1普通用户2供应商',
  `gift_money` int(11) NULL DEFAULT 0 COMMENT '虚拟币，刷礼物',
  `real_name` varchar(30) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '姓名',
  `agent_time` int(11) NOT NULL DEFAULT 0 COMMENT '推广绑定时间',
  `is_delete` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否删除',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`user_id`) USING BTREE,
  INDEX `openid`(`open_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 2 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '用户记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_user
-- ----------------------------
INSERT INTO `zmodu_user` VALUES (1, '', '', '', '', '', 'h5', '会员1', '13800138000', 'e10adc3949ba59abbe56e057f20f883e', '', 0, '', '', '', 0, 100000.00, 0.00, 0.00, 0.00, 1, 10092, 0.00, 0, 0.00, 0.00, 1, 0, '', 0, 0, 10001, 1720666179, 1720666191);

-- ----------------------------
-- Table structure for zmodu_user_address
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_user_address`;
CREATE TABLE `zmodu_user_address`  (
  `address_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `name` varchar(30) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '收货人姓名',
  `phone` varchar(20) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '联系电话',
  `province_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '所在省份id',
  `city_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '所在城市id',
  `region_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '所在区id',
  `district` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '新市辖区(该字段用于记录region表中没有的市辖区)',
  `detail` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '详细地址',
  `user_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '用户id',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`address_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '用户收货地址表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_user_address
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_user_balance_log
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_user_balance_log`;
CREATE TABLE `zmodu_user_balance_log`  (
  `log_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `user_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '用户id',
  `scene` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '余额变动场景(10用户充值 20用户消费 30管理员操作 40订单退款)',
  `money` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '变动金额',
  `describe` varchar(500) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '描述/说明',
  `remark` varchar(500) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '管理员备注',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序商城id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  PRIMARY KEY (`log_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 2 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '用户余额变动明细表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_user_balance_log
-- ----------------------------
INSERT INTO `zmodu_user_balance_log` VALUES (1, 1, 30, 100000.00, '后台管理员 [admin] 操作', '', 10001, 1720666226);

-- ----------------------------
-- Table structure for zmodu_user_cart
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_user_cart`;
CREATE TABLE `zmodu_user_cart`  (
  `cart_id` int(11) NOT NULL AUTO_INCREMENT COMMENT 'ID',
  `user_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '用户id',
  `product_id` int(11) NOT NULL COMMENT '商品',
  `spec_sku_id` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL DEFAULT '' COMMENT '商品规格',
  `total_num` int(11) NOT NULL COMMENT '商品数量',
  `join_price` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '加入时价格',
  `shop_supplier_id` int(11) NOT NULL DEFAULT 0 COMMENT '供应商id',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT 'app_id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`cart_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8mb4 COLLATE = utf8mb4_general_ci COMMENT = '用户购物车' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_user_cart
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_user_cash
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_user_cash`;
CREATE TABLE `zmodu_user_cash`  (
  `id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `user_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '分销商用户id',
  `money` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '提现金额',
  `pay_type` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '打款方式 (10微信 20支付宝 30银行卡)',
  `alipay_name` varchar(30) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '支付宝姓名',
  `alipay_account` varchar(30) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '支付宝账号',
  `bank_name` varchar(30) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '开户行名称',
  `bank_account` varchar(30) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '银行开户名',
  `bank_card` varchar(30) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '银行卡号',
  `apply_status` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '申请状态 (10待审核 20审核通过 30驳回 40已打款 50待用户确认收款)',
  `audit_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '审核时间',
  `reject_reason` varchar(500) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '驳回原因',
  `real_money` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '实际到账金额',
  `cash_ratio` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '提现比例',
  `batch_id` varchar(100) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '商家转账到零钱批次id',
  `out_bill_no` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NULL DEFAULT '' COMMENT '商户系统内部的商家单号',
  `package_info` text CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NULL COMMENT '跳转领取页面的package信息',
  `pay_time` int(11) NOT NULL DEFAULT 0 COMMENT '微信发起付款时间',
  `source` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '提现客户端来源',
  `out_biz_no` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '支付宝转账商户订单号',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '分销商提现明细表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_user_cash
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_user_coupon
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_user_coupon`;
CREATE TABLE `zmodu_user_coupon`  (
  `user_coupon_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `coupon_id` int(10) UNSIGNED NOT NULL COMMENT '优惠券id',
  `name` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '优惠券名称',
  `color` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '优惠券颜色(10蓝 20红 30紫 40黄)',
  `coupon_type` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '优惠券类型(10满减券 20折扣券)',
  `reduce_price` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '满减券-减免金额',
  `discount` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '折扣券-折扣率(0-100)',
  `min_price` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '最低消费金额',
  `expire_type` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '到期类型(10领取后生效 20固定时间)',
  `expire_day` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '领取后生效-有效天数',
  `start_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '有效期开始时间',
  `end_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '有效期结束时间',
  `apply_range` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '适用范围(10全部商品 20指定商品)',
  `is_expire` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否过期(0未过期 1已过期)',
  `is_use` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否已使用(0未使用 1已使用)',
  `user_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '用户id',
  `shop_supplier_id` int(11) NOT NULL DEFAULT 0 COMMENT '供应商id',
  `max_price` decimal(10, 2) UNSIGNED NOT NULL DEFAULT 0.00 COMMENT '最多抵扣金额',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`user_coupon_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '用户优惠券记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_user_coupon
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_user_favorite
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_user_favorite`;
CREATE TABLE `zmodu_user_favorite`  (
  `favorite_id` int(11) NOT NULL AUTO_INCREMENT COMMENT 'ID',
  `user_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '用户id',
  `pid` int(11) NOT NULL COMMENT '商品/店铺id',
  `type` tinyint(1) NOT NULL DEFAULT 0 COMMENT '10店铺20商品',
  `shop_supplier_id` int(11) NULL DEFAULT 0 COMMENT '供应商id',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(11) NOT NULL DEFAULT 0,
  PRIMARY KEY (`favorite_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8mb4 COLLATE = utf8mb4_general_ci COMMENT = '我的收藏关注' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_user_favorite
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_user_gift_log
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_user_gift_log`;
CREATE TABLE `zmodu_user_gift_log`  (
  `log_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `user_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '用户id',
  `money` int(11) NOT NULL DEFAULT 0 COMMENT '变动数量',
  `describe` varchar(500) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '描述/说明',
  `remark` varchar(500) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '管理员备注',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序商城id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  PRIMARY KEY (`log_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '用户礼物币变动明细表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_user_gift_log
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_user_grade
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_user_grade`;
CREATE TABLE `zmodu_user_grade`  (
  `grade_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '等级ID',
  `name` varchar(50) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '等级名称',
  `open_money` tinyint(4) NULL DEFAULT 0 COMMENT '是否开放0，否1是',
  `upgrade_money` int(11) NOT NULL DEFAULT 0 COMMENT '升级条件',
  `open_points` tinyint(4) NULL DEFAULT 0 COMMENT '积分是否开放0否1是',
  `upgrade_points` int(11) NULL DEFAULT 0 COMMENT '累计积分升级',
  `open_invite` tinyint(4) NULL DEFAULT 0 COMMENT '邀请是否开放0否1是',
  `upgrade_invite` int(11) NULL DEFAULT 0 COMMENT '邀请人数升级',
  `equity` int(11) NOT NULL DEFAULT 100 COMMENT '等级权益,百分比',
  `is_default` tinyint(4) NULL DEFAULT 0 COMMENT '是否默认，1是，0否',
  `remark` varchar(500) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '备注',
  `weight` tinyint(4) NULL DEFAULT 100 COMMENT '权重',
  `give_points` int(11) NULL DEFAULT 0 COMMENT '奖励积分',
  `image` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '背景图',
  `font_color` varchar(100) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL DEFAULT '#333333' COMMENT '文字颜色',
  `is_delete` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否删除',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`grade_id`) USING BTREE,
  INDEX `app_id`(`app_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 2 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '用户会员等级表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_user_grade
-- ----------------------------
INSERT INTO `zmodu_user_grade` VALUES (1, '普通会员', 0, 1000, 0, 0, 0, 0, 100, 1, '新用户即为该等级', 100, 0, '', '#333333', 0, 10001, 1592021560, 1597460481);

-- ----------------------------
-- Table structure for zmodu_user_grade_equity
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_user_grade_equity`;
CREATE TABLE `zmodu_user_grade_equity`  (
  `equity_id` int(11) NOT NULL AUTO_INCREMENT COMMENT 'ID',
  `name` varchar(100) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL DEFAULT '' COMMENT '名称',
  `image` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL DEFAULT '' COMMENT '图片',
  `status` tinyint(1) NOT NULL DEFAULT 1 COMMENT '状态0关闭1启用',
  `sort` int(10) NOT NULL DEFAULT 0 COMMENT '排序',
  `is_delete` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '是否删除',
  `app_id` int(11) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(11) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(11) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`equity_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '等级权益' ROW_FORMAT = Compact;

-- ----------------------------
-- Records of zmodu_user_grade_equity
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_user_grade_log
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_user_grade_log`;
CREATE TABLE `zmodu_user_grade_log`  (
  `log_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `user_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '用户id',
  `old_grade_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '变更前的等级id',
  `new_grade_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '变更后的等级id',
  `change_type` tinyint(3) UNSIGNED NOT NULL DEFAULT 10 COMMENT '变更类型(10后台管理员设置 20自动升级)',
  `remark` varchar(500) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '管理员备注',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  PRIMARY KEY (`log_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '用户会员等级变更记录表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_user_grade_log
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_user_points_log
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_user_points_log`;
CREATE TABLE `zmodu_user_points_log`  (
  `log_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `user_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '用户id',
  `value` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '变动数量',
  `describe` varchar(500) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '描述/说明',
  `remark` varchar(500) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '管理员备注',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序商城id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  PRIMARY KEY (`log_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '用户积分变动明细表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_user_points_log
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_user_referee
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_user_referee`;
CREATE TABLE `zmodu_user_referee`  (
  `id` int(11) NOT NULL AUTO_INCREMENT COMMENT 'ID',
  `user_id` int(11) NOT NULL DEFAULT 0 COMMENT '会员id',
  `referee_id` int(11) NOT NULL DEFAULT 0 COMMENT '推荐人id',
  `type` tinyint(3) NOT NULL DEFAULT 10 COMMENT '变动类型10注册绑定20扫码绑定30后台操作',
  `app_id` int(11) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(11) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(11) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '推荐变动记录表' ROW_FORMAT = Compact;

-- ----------------------------
-- Records of zmodu_user_referee
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_user_sign
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_user_sign`;
CREATE TABLE `zmodu_user_sign`  (
  `user_sign_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `user_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '用户id',
  `sign_date` varchar(24) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '' COMMENT '签到日期',
  `sign_day` tinyint(3) UNSIGNED NOT NULL DEFAULT 0 COMMENT '签到当月天数',
  `days` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '连续签到天数',
  `points` int(11) NULL DEFAULT 0 COMMENT '签到积分',
  `prize` text CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL COMMENT '签到奖品',
  `coupon` text CHARACTER SET utf8 COLLATE utf8_general_ci NULL COMMENT '优惠券信息',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '签到时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`user_sign_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '用户签到表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_user_sign
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_user_tag
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_user_tag`;
CREATE TABLE `zmodu_user_tag`  (
  `user_tag_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键id',
  `user_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '用户id',
  `tag_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '标签id',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '签到时间',
  PRIMARY KEY (`user_tag_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '用户标签表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_user_tag
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_user_task_log
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_user_task_log`;
CREATE TABLE `zmodu_user_task_log`  (
  `log_id` int(11) NOT NULL AUTO_INCREMENT COMMENT 'ID',
  `user_id` int(11) NOT NULL DEFAULT 0 COMMENT '会员id',
  `task_type` varchar(100) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL DEFAULT '' COMMENT '任务类型',
  `task_time` varchar(50) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL DEFAULT '' COMMENT '任务时间',
  `points` decimal(10, 2) NOT NULL DEFAULT 0.00 COMMENT '积分',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '小程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '签到时间',
  `update_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '更新时间',
  PRIMARY KEY (`log_id`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8mb4 COLLATE = utf8mb4_general_ci COMMENT = '任务记录' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_user_task_log
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_user_visit
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_user_visit`;
CREATE TABLE `zmodu_user_visit`  (
  `visit_id` int(11) NOT NULL AUTO_INCREMENT COMMENT 'ID',
  `user_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '用户id',
  `shop_supplier_id` int(11) NOT NULL COMMENT '供应商id',
  `product_id` int(11) NOT NULL DEFAULT 0 COMMENT '商品id',
  `content` varchar(1000) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NULL DEFAULT '' COMMENT '访问内容',
  `visitcode` varchar(32) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NULL DEFAULT '' COMMENT '访客id',
  `app_id` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '程序id',
  `create_time` int(10) UNSIGNED NOT NULL DEFAULT 0 COMMENT '创建时间',
  `update_time` int(11) NOT NULL DEFAULT 0,
  PRIMARY KEY (`visit_id`) USING BTREE,
  INDEX `idx_visitcode`(`visitcode`) USING BTREE
) ENGINE = InnoDB AUTO_INCREMENT = 1 CHARACTER SET = utf8mb4 COLLATE = utf8mb4_general_ci COMMENT = '用户访问记录' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_user_visit
-- ----------------------------

-- ----------------------------
-- Table structure for zmodu_version
-- ----------------------------
DROP TABLE IF EXISTS `zmodu_version`;
CREATE TABLE `zmodu_version`  (
  `version` varchar(255) CHARACTER SET utf8 COLLATE utf8_general_ci NULL DEFAULT '' COMMENT '当前版本'
) ENGINE = InnoDB CHARACTER SET = utf8 COLLATE = utf8_general_ci COMMENT = '系统信息表' ROW_FORMAT = COMPACT;

-- ----------------------------
-- Records of zmodu_version
-- ----------------------------
INSERT INTO `zmodu_version` VALUES ('2.6');

SET FOREIGN_KEY_CHECKS = 1;
