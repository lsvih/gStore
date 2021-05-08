/*=============================================================================
# Filename: PlanTree.h
# Author: Linglin Yang
# Mail: fyulingi@gmail.com
=============================================================================*/

#ifndef GSTORE_PLANTREE_H
#define GSTORE_PLANTREE_H

#include <vector>

using namespace std;

enum class NodeJoinType{ JoinANode, JoinTwoTable, LeafNode };

struct Tree_node{
    NodeJoinType joinType;

//    just for joinType == JoinANode
    int node_to_join;

    Tree_node *left_node;
    Tree_node *right_node;

    Tree_node(){};

    Tree_node(int next_node){
        joinType = NodeJoinType::LeafNode;
        node_to_join = next_node;
        left_node = nullptr;
        right_node = nullptr;
    }

    Tree_node(Tree_node *node_need_copy){
        joinType = node_need_copy->joinType;
        if(joinType == NodeJoinType::LeafNode){
            node_to_join = node_need_copy->node_to_join;
        }

        if(node_need_copy->left_node != nullptr){
            left_node = new Tree_node(node_need_copy->left_node);
        } else{
            left_node = nullptr;
        }

        if(node_need_copy->right_node != nullptr){
            right_node = new Tree_node(node_need_copy->right_node);
        } else{
            right_node = nullptr;
        }
    }
};

class PlanTree {

public:
    Tree_node *root_node;
    unsigned plan_cost;

    PlanTree(int first_node);
    PlanTree(PlanTree *last_plantree, int next_node);
    PlanTree(PlanTree *left_plan, PlanTree *right_plan);
};


#endif //GSTORE_PLANTREE_H
