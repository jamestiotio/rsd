// Copyright 2019- RSD contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.


//
// Complex Integer Execution stage
//
// 乗算/SIMD 命令の演算を行う
// COMPLEX_EXEC_STAGE_DEPTH 段にパイプライン化されている
//

`include "BasicMacros.sv"
import BasicTypes::*;
import OpFormatTypes::*;
import ActiveListIndexTypes::*;

module MulDivUnit(MulDivUnitIF.MulDivUnit port, RecoveryManagerIF.MulDivUnit recovery);

    for (genvar i = 0; i < MULDIV_ISSUE_WIDTH; i++) begin : BlockMulUnit
        // MultiplierUnit
        PipelinedMultiplierUnit #(
            .BIT_WIDTH(DATA_WIDTH),
            .PIPELINE_DEPTH(MULDIV_STAGE_DEPTH)
        ) mulUnit (
            .clk(port.clk),
            .stall(port.stall),
            .fuOpA_In(port.dataInA[i]),
            .fuOpB_In(port.dataInB[i]),
            .getUpper(port.mulGetUpper[i]),
            .mulCode(port.mulCode[i]),
            .dataOut(port.mulDataOut[i])
        );
    end


    //
    // DividerUnit
    //

    typedef enum logic[1:0]
    {
        DIVIDER_PHASE_FREE       = 0,  // Divider is free
        DIVIDER_PHASE_RESERVED   = 1,  // Divider is not processing but reserved
        DIVIDER_PHASE_PROCESSING = 2,  // In processing
        DIVIDER_PHASE_WAITING    = 3   // Wait for issuing div from the replay queue
    } DividerPhase;
    DividerPhase regPhase  [MULDIV_ISSUE_WIDTH];
    DividerPhase nextPhase [MULDIV_ISSUE_WIDTH];
    logic finished[MULDIV_ISSUE_WIDTH];

    logic flush[MULDIV_ISSUE_WIDTH];
    logic rst_divider[MULDIV_ISSUE_WIDTH];
    ActiveListIndexPath regActiveListPtr[MULDIV_ISSUE_WIDTH];
    ActiveListIndexPath nextActiveListPtr[MULDIV_ISSUE_WIDTH];

    for (genvar i = 0; i < MULDIV_ISSUE_WIDTH; i++) begin : BlockDivUnit
        DividerUnit divUnit(
            .clk(port.clk),
            .rst(rst_divider[i]),
            .req(port.divReq[i]),
            .fuOpA_In(port.dataInA[i]),
            .fuOpB_In(port.dataInB[i]),
            .divCode(port.divCode[i]),
            .finished(finished[i]),
            .dataOut(port.divDataOut[i])
        );
    end

    always_ff @(posedge port.clk) begin
        if (port.rst) begin
            for (int i = 0; i < MULDIV_ISSUE_WIDTH; i++) begin
                regPhase[i] <= DIVIDER_PHASE_FREE;
                regActiveListPtr[i] <= 0;
            end
        end
        else begin
            regPhase <= nextPhase;
            regActiveListPtr <= nextActiveListPtr;
        end
    end

    always_comb begin
        nextPhase = regPhase;
        nextActiveListPtr = regActiveListPtr;

        for (int i = 0; i < MULDIV_ISSUE_WIDTH; i++) begin

            case (regPhase[i])
            default: begin
                nextPhase[i] = DIVIDER_PHASE_FREE;
            end

            DIVIDER_PHASE_FREE: begin
                // Reserve divider and do not issue any div after that.
                if (port.divAcquire[i]) begin
                    nextPhase[i] = DIVIDER_PHASE_RESERVED;
                    nextActiveListPtr[i] = port.acquireActiveListPtr[i];
                end
            end

            DIVIDER_PHASE_RESERVED: begin
                // Request to the divider
                // NOT make a request when below situation
                // 1) When any operands of inst. are invalid
                // 2) When the divider is waiting for the instruction
                //    to receive the result of the divider
                if (port.divReq[i]) begin
                    // Receive the request of div, 
                    // so move to processing phase
                    nextPhase[i] = DIVIDER_PHASE_PROCESSING;
                end
            end

            DIVIDER_PHASE_PROCESSING: begin
                // Div operation has finished, so we can get result from divider
                if (finished[i]) begin
                    nextPhase[i] = DIVIDER_PHASE_WAITING;
                end
            end

            DIVIDER_PHASE_WAITING: begin
                if (port.divRelease[i]) begin 
                    // Divが除算器から結果を取得できたので，
                    // IQからのdivの発行を許可する 
                    nextPhase[i] = DIVIDER_PHASE_FREE;
                end
            end
            endcase // regPhase[i]


            // Cancel divider allocation on pipeline flush
            flush[i] = SelectiveFlushDetector(
                recovery.toRecoveryPhase,
                recovery.flushRangeHeadPtr,
                recovery.flushRangeTailPtr,
                recovery.flushAllInsns,
                regActiveListPtr[i]
            );

            // 除算器に要求をしたdivがフラッシュされたので，除算器を解放する
            if (flush[i]) begin
                nextPhase[i] = DIVIDER_PHASE_FREE;
            end
            rst_divider[i] = port.rst | flush[i];

            // 現状 acquire が issue ステージからくるので，次のサイクルの状態でフリーか
            // どうかを判定する必要がある
            port.divFree[i]     = nextPhase[i] == DIVIDER_PHASE_FREE ? TRUE : FALSE;   
            port.divFinished[i] = regPhase[i] == DIVIDER_PHASE_WAITING ? TRUE : FALSE;
            port.divBusy[i]     = regPhase[i] == DIVIDER_PHASE_PROCESSING ? TRUE : FALSE;
            port.divReserved[i] = regPhase[i] == DIVIDER_PHASE_RESERVED ? TRUE : FALSE;

        end // for (int i = 0; i < MULDIV_ISSUE_WIDTH; i++) begin

    end // always_comb begin


endmodule
